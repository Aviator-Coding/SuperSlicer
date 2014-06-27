package Slic3r::GUI::MainFrame;
use strict;
use warnings;
use utf8;

use File::Basename qw(basename dirname);
use List::Util qw(min);
use Slic3r::Geometry qw(X Y Z);
use Wx qw(:frame :bitmap :id :misc :notebook :panel :sizer :menu :dialog :filedialog
    :font :icon wxTheApp);
use Wx::Event qw(EVT_CLOSE EVT_MENU);
use base 'Wx::Frame';

our $last_input_file;
our $last_output_file;
our $last_config;

sub new {
    my ($class, %params) = @_;
    
    my $self = $class->SUPER::new(undef, -1, 'Slic3r', wxDefaultPosition, wxDefaultSize, wxDEFAULT_FRAME_STYLE);
    $self->SetIcon(Wx::Icon->new("$Slic3r::var/Slic3r_128px.png", wxBITMAP_TYPE_PNG) );
    
    # store input params
    $self->{mode} = $params{mode};
    $self->{mode} = 'expert' if $self->{mode} !~ /^(?:simple|expert)$/;
    $self->{no_plater} = $params{no_plater};
    $self->{loaded} = 0;
    
    # initialize tabpanel and menubar
    $self->_init_tabpanel;
    $self->_init_menubar;
    
    # initialize status bar
    $self->{statusbar} = Slic3r::GUI::ProgressStatusBar->new($self, -1);
    $self->{statusbar}->SetStatusText("Version $Slic3r::VERSION - Remember to check for updates at http://slic3r.org/");
    $self->SetStatusBar($self->{statusbar});
    
    $self->{loaded} = 1;
    
    # declare events
    EVT_CLOSE($self, sub {
        my (undef, $event) = @_;
        if ($event->CanVeto && !$self->check_unsaved_changes) {
            $event->Veto;
            return;
        }
        $event->Skip;
    });
    
    # initialize layout
    {
        my $sizer = Wx::BoxSizer->new(wxVERTICAL);
        $sizer->Add($self->{tabpanel}, 1, wxEXPAND);
        $sizer->SetSizeHints($self);
        $self->SetSizer($sizer);
        $self->Fit;
        $self->SetMinSize([760, 470]);
        $self->SetSize($self->GetMinSize);
        $self->Show;
        $self->Layout;
    }
    
    return $self;
}

sub _init_tabpanel {
    my ($self) = @_;
    
    $self->{tabpanel} = my $panel = Wx::Notebook->new($self, -1, wxDefaultPosition, wxDefaultSize, wxNB_TOP | wxTAB_TRAVERSAL);
    
    $panel->AddPage($self->{plater} = Slic3r::GUI::Plater->new($panel), "Plater")
        unless $self->{no_plater};
    $self->{options_tabs} = {};
    
    my $simple_config;
    if ($self->{mode} eq 'simple') {
        $simple_config = Slic3r::Config->load("$Slic3r::GUI::datadir/simple.ini")
            if -e "$Slic3r::GUI::datadir/simple.ini";
    }
    
    my $class_prefix = $self->{mode} eq 'simple' ? "Slic3r::GUI::SimpleTab::" : "Slic3r::GUI::Tab::";
    for my $tab_name (qw(print filament printer)) {
        my $tab;
        $tab = $self->{options_tabs}{$tab_name} = ($class_prefix . ucfirst $tab_name)->new(
            $panel,
            on_value_change     => sub {
                $self->{plater}->on_config_change(@_) if $self->{plater}; # propagate config change events to the plater
                if ($self->{loaded}) {  # don't save while loading for the first time
                    if ($self->{mode} eq 'simple') {
                        # save config
                        $self->config->save("$Slic3r::GUI::datadir/simple.ini");
                        
                        # save a copy into each preset section
                        # so that user gets the config when switching to expert mode
                        $tab->config->save(sprintf "$Slic3r::GUI::datadir/%s/%s.ini", $tab->name, 'Simple Mode');
                        $Slic3r::GUI::Settings->{presets}{$tab->name} = 'Simple Mode.ini';
                        wxTheApp->save_settings;
                    }
                    $self->config->save($Slic3r::GUI::autosave) if $Slic3r::GUI::autosave;
                }
            },
            on_presets_changed  => sub {
                $self->{plater}->update_presets($tab_name, @_) if $self->{plater};
            },
        );
        $panel->AddPage($tab, $tab->title);
        $tab->load_config($simple_config) if $simple_config;
    }
}

sub _init_menubar {
    my ($self) = @_;
    
    # File menu
    my $fileMenu = Wx::Menu->new;
    {
        $self->_append_menu_item($fileMenu, "&Load Config…\tCtrl+L", 'Load exported configuration file', sub {
            $self->load_config_file;
        });
        $self->_append_menu_item($fileMenu, "&Export Config…\tCtrl+E", 'Export current configuration to file', sub {
            $self->export_config;
        });
        $self->_append_menu_item($fileMenu, "&Load Config Bundle…", 'Load presets from a bundle', sub {
            $self->load_configbundle;
        });
        $self->_append_menu_item($fileMenu, "&Export Config Bundle…", 'Export all presets to file', sub {
            $self->export_configbundle;
        });
        $fileMenu->AppendSeparator();
        my $repeat;
        $self->_append_menu_item($fileMenu, "Q&uick Slice…\tCtrl+U", 'Slice file', sub {
            $self->quick_slice;
            $repeat->Enable(defined $Slic3r::GUI::MainFrame::last_input_file);
        });
        $self->_append_menu_item($fileMenu, "Quick Slice and Save &As…\tCtrl+Alt+U", 'Slice file and save as', sub {
            $self->quick_slice(save_as => 1);
            $repeat->Enable(defined $Slic3r::GUI::MainFrame::last_input_file);
        });
        $repeat = $self->_append_menu_item($fileMenu, "&Repeat Last Quick Slice\tCtrl+Shift+U", 'Repeat last quick slice', sub {
            $self->quick_slice(reslice => 1);
        });
        $repeat->Enable(0);
        $fileMenu->AppendSeparator();
        $self->_append_menu_item($fileMenu, "Slice to SV&G…\tCtrl+G", 'Slice file to SVG', sub {
            $self->quick_slice(save_as => 1, export_svg => 1);
        });
        $fileMenu->AppendSeparator();
        $self->_append_menu_item($fileMenu, "Repair STL file…", 'Automatically repair an STL file', sub {
            $self->repair_stl;
        });
        $self->_append_menu_item($fileMenu, "Combine multi-material STL files…", 'Combine multiple STL files into a single multi-material AMF file', sub {
            $self->combine_stls;
        });
        $fileMenu->AppendSeparator();
        $self->_append_menu_item($fileMenu, "Preferences…", 'Application preferences', sub {
            Slic3r::GUI::Preferences->new($self)->ShowModal;
        });
        $fileMenu->AppendSeparator();
        $self->_append_menu_item($fileMenu, "&Quit", 'Quit Slic3r', sub {
            $self->Close(0);
        });
    }
    
    # Plater menu
    unless ($self->{no_plater}) {
        my $plater = $self->{plater};
        
        $self->{plater_menu} = Wx::Menu->new;
        $self->_append_menu_item($self->{plater_menu}, "Export G-code...", 'Export current plate as G-code', sub {
            $plater->export_gcode;
        });
        $self->_append_menu_item($self->{plater_menu}, "Export STL...", 'Export current plate as STL', sub {
            $plater->export_stl;
        });
        $self->_append_menu_item($self->{plater_menu}, "Export AMF...", 'Export current plate as AMF', sub {
            $plater->export_amf;
        });
        
        $self->{object_menu} = $self->{plater}->object_menu;
        $self->on_plater_selection_changed(0);
    }
    
    # Window menu
    my $windowMenu = Wx::Menu->new;
    {
        my $tab_count = $self->{no_plater} ? 3 : 4;
        $self->_append_menu_item($windowMenu, "Select &Plater Tab\tCtrl+1", 'Show the plater', sub {
            $self->select_tab(0);
        }) unless $self->{no_plater};
        $self->_append_menu_item($windowMenu, "Select P&rint Settings Tab\tCtrl+2", 'Show the print settings', sub {
            $self->select_tab($tab_count-3);
        });
        $self->_append_menu_item($windowMenu, "Select &Filament Settings Tab\tCtrl+3", 'Show the filament settings', sub {
            $self->select_tab($tab_count-2);
        });
        $self->_append_menu_item($windowMenu, "Select Print&er Settings Tab\tCtrl+4", 'Show the printer settings', sub {
            $self->select_tab($tab_count-1);
        });
    }
    
    # Help menu
    my $helpMenu = Wx::Menu->new;
    {
        $self->_append_menu_item($helpMenu, "&Configuration $Slic3r::GUI::ConfigWizard::wizard…", "Run Configuration $Slic3r::GUI::ConfigWizard::wizard", sub {
            $self->config_wizard;
        });
        $helpMenu->AppendSeparator();
        $self->_append_menu_item($helpMenu, "Slic3r &Website", 'Open the Slic3r website in your browser', sub {
            Wx::LaunchDefaultBrowser('http://slic3r.org/');
        });
        my $versioncheck = $self->_append_menu_item($helpMenu, "Check for &Updates...", 'Check for new Slic3r versions', sub {
            wxTheApp->check_version(manual => 1);
        });
        $versioncheck->Enable(wxTheApp->have_version_check);
        $self->_append_menu_item($helpMenu, "Slic3r &Manual", 'Open the Slic3r manual in your browser', sub {
            Wx::LaunchDefaultBrowser('http://manual.slic3r.org/');
        });
        $helpMenu->AppendSeparator();
        $self->_append_menu_item($helpMenu, "&About Slic3r", 'Show about dialog', sub {
            wxTheApp->about;
        });
    }
    
    # menubar
    # assign menubar to frame after appending items, otherwise special items
    # will not be handled correctly
    {
        my $menubar = Wx::MenuBar->new;
        $menubar->Append($fileMenu, "&File");
        $menubar->Append($self->{plater_menu}, "&Plater") if $self->{plater_menu};
        $menubar->Append($self->{object_menu}, "&Object") if $self->{object_menu};
        $menubar->Append($windowMenu, "&Window");
        $menubar->Append($helpMenu, "&Help");
        $self->SetMenuBar($menubar);
    }
}

sub is_loaded {
    my ($self) = @_;
    return $self->{loaded};
}

sub on_plater_selection_changed {
    my ($self, $have_selection) = @_;
    
    return if !defined $self->{object_menu};
    $self->{object_menu}->Enable($_->GetId, $have_selection)
        for $self->{object_menu}->GetMenuItems;
}

sub quick_slice {
    my $self = shift;
    my %params = @_;
    
    my $progress_dialog;
    eval {
        # validate configuration
        my $config = $self->config;
        $config->validate;
        
        # select input file
        my $input_file;
        my $dir = $Slic3r::GUI::Settings->{recent}{skein_directory} || $Slic3r::GUI::Settings->{recent}{config_directory} || '';
        if (!$params{reslice}) {
            my $dialog = Wx::FileDialog->new($self, 'Choose a file to slice (STL/OBJ/AMF):', $dir, "", &Slic3r::GUI::MODEL_WILDCARD, wxFD_OPEN | wxFD_FILE_MUST_EXIST);
            if ($dialog->ShowModal != wxID_OK) {
                $dialog->Destroy;
                return;
            }
            $input_file = $dialog->GetPaths;
            $dialog->Destroy;
            $last_input_file = $input_file unless $params{export_svg};
        } else {
            if (!defined $last_input_file) {
                Wx::MessageDialog->new($self, "No previously sliced file.",
                                       'Error', wxICON_ERROR | wxOK)->ShowModal();
                return;
            }
            if (! -e $last_input_file) {
                Wx::MessageDialog->new($self, "Previously sliced file ($last_input_file) not found.",
                                       'File Not Found', wxICON_ERROR | wxOK)->ShowModal();
                return;
            }
            $input_file = $last_input_file;
        }
        my $input_file_basename = basename($input_file);
        $Slic3r::GUI::Settings->{recent}{skein_directory} = dirname($input_file);
        wxTheApp->save_settings;
        
        my $sprint = Slic3r::Print::Simple->new(
            status_cb       => sub {
                my ($percent, $message) = @_;
                return if &Wx::wxVERSION_STRING !~ / 2\.(8\.|9\.[2-9])/;
                $progress_dialog->Update($percent, "$message…");
            },
        );
        
        # keep model around
        my $model = Slic3r::Model->read_from_file($input_file);
        
        $sprint->apply_config($config);
        $sprint->set_model($model);
        
        {
            my $extra = $self->extra_variables;
            $sprint->placeholder_parser->set($_, $extra->{$_}) for keys %$extra;
        }
        
        # select output file
        my $output_file;
        if ($params{reslice}) {
            $output_file = $last_output_file if defined $last_output_file;
        } elsif ($params{save_as}) {
            $output_file = $sprint->expanded_output_filepath;
            $output_file =~ s/\.gcode$/.svg/i if $params{export_svg};
            my $dlg = Wx::FileDialog->new($self, 'Save ' . ($params{export_svg} ? 'SVG' : 'G-code') . ' file as:',
                wxTheApp->output_path(dirname($output_file)),
                basename($output_file), $params{export_svg} ? &Slic3r::GUI::FILE_WILDCARDS->{svg} : &Slic3r::GUI::FILE_WILDCARDS->{gcode}, wxFD_SAVE);
            if ($dlg->ShowModal != wxID_OK) {
                $dlg->Destroy;
                return;
            }
            $output_file = $dlg->GetPath;
            $last_output_file = $output_file unless $params{export_svg};
            $Slic3r::GUI::Settings->{_}{last_output_path} = dirname($output_file);
            wxTheApp->save_settings;
            $dlg->Destroy;
        }
        
        # show processbar dialog
        $progress_dialog = Wx::ProgressDialog->new('Slicing…', "Processing $input_file_basename…", 
            100, $self, 0);
        $progress_dialog->Pulse;
        
        {
            my @warnings = ();
            local $SIG{__WARN__} = sub { push @warnings, $_[0] };
            
            $sprint->output_file($output_file);
            if ($params{export_svg}) {
                $sprint->export_svg;
            } else {
                $sprint->export_gcode;
            }
            $sprint->status_cb(undef);
            Slic3r::GUI::warning_catcher($self)->($_) for @warnings;
        }
        $progress_dialog->Destroy;
        undef $progress_dialog;
        
        my $message = "$input_file_basename was successfully sliced.";
        wxTheApp->notify($message);
        Wx::MessageDialog->new($self, $message, 'Slicing Done!', 
            wxOK | wxICON_INFORMATION)->ShowModal;
    };
    Slic3r::GUI::catch_error($self, sub { $progress_dialog->Destroy if $progress_dialog });
}

sub repair_stl {
    my $self = shift;
    
    my $input_file;
    {
        my $dir = $Slic3r::GUI::Settings->{recent}{skein_directory} || $Slic3r::GUI::Settings->{recent}{config_directory} || '';
        my $dialog = Wx::FileDialog->new($self, 'Select the STL file to repair:', $dir, "", &Slic3r::GUI::FILE_WILDCARDS->{stl}, wxFD_OPEN | wxFD_FILE_MUST_EXIST);
        if ($dialog->ShowModal != wxID_OK) {
            $dialog->Destroy;
            return;
        }
        $input_file = $dialog->GetPaths;
        $dialog->Destroy;
    }
    
    my $output_file = $input_file;
    {
        $output_file =~ s/\.stl$/_fixed.obj/i;
        my $dlg = Wx::FileDialog->new($self, "Save OBJ file (less prone to coordinate errors than STL) as:", dirname($output_file),
            basename($output_file), &Slic3r::GUI::FILE_WILDCARDS->{obj}, wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
        if ($dlg->ShowModal != wxID_OK) {
            $dlg->Destroy;
            return undef;
        }
        $output_file = $dlg->GetPath;
        $dlg->Destroy;
    }
    
    my $tmesh = Slic3r::TriangleMesh->new;
    $tmesh->ReadSTLFile(Slic3r::encode_path($input_file));
    $tmesh->repair;
    $tmesh->WriteOBJFile(Slic3r::encode_path($output_file));
    Slic3r::GUI::show_info($self, "Your file was repaired.", "Repair");
}

sub extra_variables {
    my $self = shift;
    
    my %extra_variables = ();
    if ($self->{mode} eq 'expert') {
        $extra_variables{"${_}_preset"} = $self->{options_tabs}{$_}->current_preset->{name}
            for qw(print filament printer);
    }
    return { %extra_variables };
}

sub export_config {
    my $self = shift;
    
    my $config = $self->config;
    eval {
        # validate configuration
        $config->validate;
    };
    Slic3r::GUI::catch_error($self) and return;
    
    my $dir = $last_config ? dirname($last_config) : $Slic3r::GUI::Settings->{recent}{config_directory} || $Slic3r::GUI::Settings->{recent}{skein_directory} || '';
    my $filename = $last_config ? basename($last_config) : "config.ini";
    my $dlg = Wx::FileDialog->new($self, 'Save configuration as:', $dir, $filename, 
        &Slic3r::GUI::FILE_WILDCARDS->{ini}, wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
    if ($dlg->ShowModal == wxID_OK) {
        my $file = $dlg->GetPath;
        $Slic3r::GUI::Settings->{recent}{config_directory} = dirname($file);
        wxTheApp->save_settings;
        $last_config = $file;
        $config->save($file);
    }
    $dlg->Destroy;
}

sub load_config_file {
    my $self = shift;
    my ($file) = @_;
    
    if (!$file) {
        return unless $self->check_unsaved_changes;
        my $dir = $last_config ? dirname($last_config) : $Slic3r::GUI::Settings->{recent}{config_directory} || $Slic3r::GUI::Settings->{recent}{skein_directory} || '';
        my $dlg = Wx::FileDialog->new($self, 'Select configuration to load:', $dir, "config.ini", 
                &Slic3r::GUI::FILE_WILDCARDS->{ini}, wxFD_OPEN | wxFD_FILE_MUST_EXIST);
        return unless $dlg->ShowModal == wxID_OK;
        ($file) = $dlg->GetPaths;
        $dlg->Destroy;
    }
    $Slic3r::GUI::Settings->{recent}{config_directory} = dirname($file);
    wxTheApp->save_settings;
    $last_config = $file;
    for my $tab (values %{$self->{options_tabs}}) {
        $tab->load_config_file($file);
    }
}

sub export_configbundle {
    my $self = shift;
    
    eval {
        # validate current configuration in case it's dirty
        $self->config->validate;
    };
    Slic3r::GUI::catch_error($self) and return;
    
    my $dir = $last_config ? dirname($last_config) : $Slic3r::GUI::Settings->{recent}{config_directory} || $Slic3r::GUI::Settings->{recent}{skein_directory} || '';
    my $filename = "Slic3r_config_bundle.ini";
    my $dlg = Wx::FileDialog->new($self, 'Save presets bundle as:', $dir, $filename, 
        &Slic3r::GUI::FILE_WILDCARDS->{ini}, wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
    if ($dlg->ShowModal == wxID_OK) {
        my $file = $dlg->GetPath;
        $Slic3r::GUI::Settings->{recent}{config_directory} = dirname($file);
        wxTheApp->save_settings;
        
        # leave default category empty to prevent the bundle from being parsed as a normal config file
        my $ini = { _ => {} };
        $ini->{settings}{$_} = $Slic3r::GUI::Settings->{_}{$_} for qw(autocenter mode);
        $ini->{presets} = $Slic3r::GUI::Settings->{presets};
        if (-e "$Slic3r::GUI::datadir/simple.ini") {
            my $config = Slic3r::Config->load("$Slic3r::GUI::datadir/simple.ini");
            $ini->{simple} = $config->as_ini->{_};
        }
        
        foreach my $section (qw(print filament printer)) {
            my %presets = wxTheApp->presets($section);
            foreach my $preset_name (keys %presets) {
                my $config = Slic3r::Config->load($presets{$preset_name});
                $ini->{"$section:$preset_name"} = $config->as_ini->{_};
            }
        }
        
        Slic3r::Config->write_ini($file, $ini);
    }
    $dlg->Destroy;
}

sub load_configbundle {
    my $self = shift;
    
    my $dir = $last_config ? dirname($last_config) : $Slic3r::GUI::Settings->{recent}{config_directory} || $Slic3r::GUI::Settings->{recent}{skein_directory} || '';
    my $dlg = Wx::FileDialog->new($self, 'Select configuration to load:', $dir, "config.ini", 
            &Slic3r::GUI::FILE_WILDCARDS->{ini}, wxFD_OPEN | wxFD_FILE_MUST_EXIST);
    return unless $dlg->ShowModal == wxID_OK;
    my ($file) = $dlg->GetPaths;
    $dlg->Destroy;
    
    $Slic3r::GUI::Settings->{recent}{config_directory} = dirname($file);
    wxTheApp->save_settings;
    
    # load .ini file
    my $ini = Slic3r::Config->read_ini($file);
    
    if ($ini->{settings}) {
        $Slic3r::GUI::Settings->{_}{$_} = $ini->{settings}{$_} for keys %{$ini->{settings}};
        wxTheApp->save_settings;
    }
    if ($ini->{presets}) {
        $Slic3r::GUI::Settings->{presets} = $ini->{presets};
        wxTheApp->save_settings;
    }
    if ($ini->{simple}) {
        my $config = Slic3r::Config->load_ini_hash($ini->{simple});
        $config->save("$Slic3r::GUI::datadir/simple.ini");
        if ($self->{mode} eq 'simple') {
            foreach my $tab (values %{$self->{options_tabs}}) {
                $tab->load_config($config) for values %{$self->{options_tabs}};
            }
        }
    }
    my $imported = 0;
    foreach my $ini_category (sort keys %$ini) {
        next unless $ini_category =~ /^(print|filament|printer):(.+)$/;
        my ($section, $preset_name) = ($1, $2);
        my $config = Slic3r::Config->load_ini_hash($ini->{$ini_category});
        $config->save(sprintf "$Slic3r::GUI::datadir/%s/%s.ini", $section, $preset_name);
        $imported++;
    }
    if ($self->{mode} eq 'expert') {
        foreach my $tab (values %{$self->{options_tabs}}) {
            $tab->load_presets;
        }
    }
    my $message = sprintf "%d presets successfully imported.", $imported;
    if ($self->{mode} eq 'simple' && $Slic3r::GUI::Settings->{_}{mode} eq 'expert') {
        Slic3r::GUI::show_info($self, "$message You need to restart Slic3r to make the changes effective.");
    } else {
        Slic3r::GUI::show_info($self, $message);
    }
}

sub load_config {
    my $self = shift;
    my ($config) = @_;
    
    foreach my $tab (values %{$self->{options_tabs}}) {
        $tab->set_value($_, $config->$_) for @{$config->get_keys};
    }
}

sub config_wizard {
    my $self = shift;

    return unless $self->check_unsaved_changes;
    if (my $config = Slic3r::GUI::ConfigWizard->new($self)->run) {
        if ($self->{mode} eq 'expert') {
            for my $tab (values %{$self->{options_tabs}}) {
                $tab->select_default_preset;
            }
        }
        $self->load_config($config);
        if ($self->{mode} eq 'expert') {
            for my $tab (values %{$self->{options_tabs}}) {
                $tab->save_preset('My Settings');
            }
        }
    }
}

sub combine_stls {
    my $self = shift;
    
    # get input files
    my @input_files = ();
    my $dir = $Slic3r::GUI::Settings->{recent}{skein_directory} || '';
    {
        my $dlg_message = 'Choose one or more files to combine (STL/OBJ)';
        while (1) {
            my $dialog = Wx::FileDialog->new($self, "$dlg_message:", $dir, "", &Slic3r::GUI::MODEL_WILDCARD, 
                wxFD_OPEN | wxFD_MULTIPLE | wxFD_FILE_MUST_EXIST);
            if ($dialog->ShowModal != wxID_OK) {
                $dialog->Destroy;
                last;
            }
            push @input_files, $dialog->GetPaths;
            $dialog->Destroy;
            $dlg_message .= " or hit Cancel if you have finished";
            $dir = dirname($input_files[0]);
        }
        return if !@input_files;
    }
    
    # get output file
    my $output_file = $input_files[0];
    {
        $output_file =~ s/\.(?:stl|obj)$/.amf.xml/i;
        my $dlg = Wx::FileDialog->new($self, 'Save multi-material AMF file as:', dirname($output_file),
            basename($output_file), &Slic3r::GUI::FILE_WILDCARDS->{amf}, wxFD_SAVE);
        if ($dlg->ShowModal != wxID_OK) {
            $dlg->Destroy;
            return;
        }
        $output_file = $dlg->GetPath;
    }
    
    my @models = eval { map Slic3r::Model->read_from_file($_), @input_files };
    Slic3r::GUI::show_error($self, $@) if $@;
    
    my $new_model = Slic3r::Model->new;
    my $new_object = $new_model->add_object;
    for my $m (0 .. $#models) {
        my $model = $models[$m];
        
        my $material_name = basename($input_files[$m]);
        $material_name =~ s/\.(stl|obj)$//i;
        
        $new_model->set_material($m, { Name => $material_name });
        $new_object->add_volume(
            material_id => $m,
            mesh        => $model->objects->[0]->volumes->[0]->mesh,
        );
    }
    
    Slic3r::Format::AMF->write_file($output_file, $new_model);
}

=head2 config

This method collects all config values from the tabs and merges them into a single config object.

=cut

sub config {
    my $self = shift;
    
    # retrieve filament presets and build a single config object for them
    my $filament_config;
    if (!$self->{plater} || $self->{plater}->filament_presets == 1 || $self->{mode} eq 'simple') {
        $filament_config = $self->{options_tabs}{filament}->config;
    } else {
        # TODO: handle dirty presets.
        # perhaps plater shouldn't expose dirty presets at all in multi-extruder environments.
        my $i = -1;
        foreach my $preset_idx ($self->{plater}->filament_presets) {
            $i++;
            my $preset = $self->{options_tabs}{filament}->get_preset($preset_idx);
            my $config = $self->{options_tabs}{filament}->get_preset_config($preset);
            if (!$filament_config) {
                $filament_config = $config->clone;
                next;
            }
            foreach my $opt_key (@{$config->get_keys}) {
                my $value = $filament_config->get($opt_key);
                next unless ref $value eq 'ARRAY';
                $value->[$i] = $config->get($opt_key)->[0];
                $filament_config->set($opt_key, $value);
            }
        }
    }
    
    my $config = Slic3r::Config->merge(
        Slic3r::Config->new_from_defaults,
        $self->{options_tabs}{print}->config,
        $self->{options_tabs}{printer}->config,
        $filament_config,
    );
    
    if ($self->{mode} eq 'simple') {
        # set some sensible defaults
        $config->set('first_layer_height', $config->nozzle_diameter->[0]);
        $config->set('avoid_crossing_perimeters', 1);
        $config->set('infill_every_layers', 10);
    } else {
        my $extruders_count = $self->{options_tabs}{printer}{extruders_count};
        $config->set("${_}_extruder", min($config->get("${_}_extruder"), $extruders_count))
            for qw(perimeter infill support_material support_material_interface);
    }
    
    return $config;
}

sub set_value {
    my $self = shift;
    my ($opt_key, $value) = @_;
    
    my $changed = 0;
    foreach my $tab (values %{$self->{options_tabs}}) {
        $changed = 1 if $tab->set_value($opt_key, $value);
    }
    return $changed;
}

sub check_unsaved_changes {
    my $self = shift;
    
    my @dirty = map $_->title, grep $_->is_dirty, values %{$self->{options_tabs}};
    if (@dirty) {
        my $titles = join ', ', @dirty;
        my $confirm = Wx::MessageDialog->new($self, "You have unsaved changes ($titles). Discard changes and continue anyway?",
                                             'Unsaved Presets', wxICON_QUESTION | wxYES_NO | wxNO_DEFAULT);
        return ($confirm->ShowModal == wxID_YES);
    }
    
    return 1;
}

sub select_tab {
    my ($self, $tab) = @_;
    $self->{tabpanel}->ChangeSelection($tab);
}

sub _append_menu_item {
    my ($self, $menu, $string, $description, $cb) = @_;
    
    my $id = &Wx::NewId();
    my $item = $menu->Append($id, $string, $description);
    EVT_MENU($self, $id, $cb);
    return $item;
}

1;
