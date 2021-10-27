use v6.d;

use JSON::Fast;
use Pod::Contents:auth<zef:CIAvash>;
use Sway::Config:auth<zef:CIAvash>;
use GtkLayerShell:auth<zef:CIAvash>:api<0.6>;

use Gnome::Gtk3::Main;
use Gnome::Gtk3::Window;
use Gnome::Gtk3::Enums;
use Gnome::Gtk3::Grid;
use Gnome::Gtk3::Label;
use Gnome::Gtk3::StyleContext;
use Gnome::Gtk3::StyleProvider;
use Gnome::Gtk3::CssProvider;
use Gnome::Gdk3::Screen;

enum HorizontalPosition (START => 'start', CENTER => 'center', END => 'end');

unit module Sway::PreviewKeys:auth($?DISTRIBUTION.meta<auth>):ver($?DISTRIBUTION.meta<version>);

=NAME sway-preview-keys

=TITLE sway-preview-keys - Shows preview windows for L<Sway|https://swaywm.org/> modes' key bindings

=begin DESCRIPTION
Gets the config from sway and parses it.

Gets the CSS style for preview windows from path specified via command option
or C<$XDG_CONFIG_HOME/sway-preview-keys/style.css> or C<$HOME/.config/sway-preview-keys/style.css>

Finally listens to Sway mode changes and shows a preview window for mode's key bindings.
=end DESCRIPTION

my $app_name        = $=pod.&join_pod_contents_of: 'NAME';
my $app_title       = $=pod.&join_pod_contents_of: 'TITLE';
my $app_description = $=pod.&join_pod_contents_of: 'DESCRIPTION', "\n", :!inline_formatters;
constant $app_version   = $?MODULE.^ver;
constant $app_copyright = q:to/END/;
Copyright (C) 2021 Siavash Askari Nasr.

License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.
This is free software: you are free to change and redistribute it.
This program comes with NO WARRANTY.
END

=begin SYNOPSIS
=begin input
Usage:
  sway-preview-keys
    [-p|--style-path<PATH>]                  -- Set CSS style path for preview window [p=path]
    [-t|--add-mode-name]                     -- Add mode name at top of the preview window [t=title]
    [-s|--sort-key-bindings]                 -- Sort mode's key bindings [s=sort]
    [-d|--bindsym-default-mode=<NAME>]       -- Bind a symbol for previewing key bindings of default mode [d=default]
    [-r|--max-rows=<NUM>]                    -- Add columns to show key bindings when number of key bindings exceed the maximum row. Can be repeated. [r=row]
                                                Biggest number which is lower than the number of key bindings is chosen, otherwise the minimum of the numbers is used
    [-e|--ellipsize=<NUM>]                   -- Ellipsize commands, given number is used for maximum characters to show. [e=ellipsize]
                                                Takes effect only when number of key bindings reaches the maximum of --max-rows
    [--ellipsis-position=<start|center|end>] -- Set the position of ellipsis. Default is center.
                                                Takes effect only when --ellipsize is used

  sway-preview-keys -v|--version -- Print version

Example:
  sway-preview-keys -d 'Mod4+o' -t -e 26 -r 20 -r 38
  sway-preview-keys --bindsym-default-mode 'Mod4+o' --add-mode-name --ellipsize 26 --max-rows 20 --max-rows 38
=end input

Example style:
=begin code :lang<css>
#preview-window {
    font-family: monospace;
    background-color: rgba(43, 24, 21, 0.9);
    color: white;
    border-radius: 10px;
}

#preview-table {
    padding: 2px 2px;
}

#mode-name {
    font-weight: bold;
    color: #CC7744;
    margin: 0 7px;
    padding: 4px 0;
    border-bottom: 1px solid rgba(95, 75, 72, 0.9);
}

#key-binding, #command {
    padding: 4px 7px;
}

#key-binding {
    color: wheat;
}

#command {
    color: #ddd;
}
=end code
=end SYNOPSIS

my Sway::Config $sway_config;

my Gnome::Gtk3::Main   $main;
my Gnome::Gtk3::Window $gtk_window;
my Gnome::Gtk3::Grid   $grid;
my Gnome::Gdk3::Screen $screen;

my Promise $preview_promise;
my Promise $main_promise;
my Bool:D $previewing = False;

proto MAIN (|) is export {*}

#| Prints version
multi MAIN (Bool:D :v(:$version)!) {
    put "$app_name v$app_version\n";

    print $app_copyright;
}

#|[
Gets the config from sway and parses it.

Gets the CSS style for preview windows from path specified via command option
or C<$XDG_CONFIG_HOME/sway-preview-keys/style.css> or C<$HOME/.config/sway-preview-keys/style.css>

Finally listens to Sway mode changes and shows a preview window for mode's key bindings.
]
multi MAIN (IO::Path(Str) :p(:$style-path) where IO::Path | .so,
            Bool:D :t(:$add-mode-name)     = False,
            Bool:D :s(:$sort-key-bindings) = False,
            Str :d(:$bindsym-default-mode),
            :r(:@max-rows) where .all ~~ IntStr,
            IntStr :e(:$ellipsize),
            Str:D :$ellipsis-position where <start center end>.any = 'center') {
    $sway_config .= new;
    $main        .= new;

    my IO::Path $style_path;
    my Str $default_bindsym = $bindsym-default-mode;

    with $style-path {
        $style_path = $_ when :f;
    } else {
        %*ENV<XDG_CONFIG_HOME> andthen .IO.add: 'sway-preview-keys', 'style.css' andthen .f && $style_path = $_
        orelse $*HOME andthen .IO.add: '.config', 'sway-preview-keys', 'style.css' andthen .f && $style_path = $_;
    }
    note 'sway-preview-keys: Could not find a CSS style file.' without $style_path;

    my Proc::Async $sway_mode_subscription    .= new: <swaymsg -t subscribe -m ["mode"]>;
    my Proc::Async $sway_binding_subscription .= new: <swaymsg -t subscribe -m ["binding"]> if $default_bindsym;

    setup_default_mode_key_binding $default_bindsym;

    with $style_path {
        my Gnome::Gtk3::CssProvider $style_provider .= new;

        with $style_provider.load-from-data(.slurp) {
            # When error is not valid
            when !.is-valid {
                $screen = Gnome::Gdk3::Screen.new;
                Gnome::Gtk3::StyleContext.new.add-provider-for-screen: $screen,
                                                                       $style_provider,
                                                                       GTK_STYLE_PROVIDER_PRIORITY_APPLICATION;
            }
            default {
                note 'sway-preview-keys: Could not parse the CSS style.';
            }
        }
    }

    my &show_preview = &preview.assuming: :sort($sort-key-bindings),
                                          :add_title($add-mode-name),
                                          :$ellipsize,
                                          :ellipsis_position(HorizontalPosition($ellipsis-position)),
                                          :max_rows(@max-rows);

    # Show preview window if a mode is already active
    with current_mode() {
        show_preview $_ when none 'default';
    }

    react {
        whenever $sway_mode_subscription.stdout.lines {
            my %mode_state = .&from-json;
            if %mode_state<change> ne 'default' {
                show_preview %mode_state<change>;
            } else {
                preview :close;
            }
        }
        whenever $sway_binding_subscription.stdout.lines {
            my %binding_state = .&from-json;
            my %binding = %binding_state<binding>;

            if %binding<command> eq 'reload' {
                $sway_config .= new;
                setup_default_mode_key_binding $default_bindsym;
            }

            if $default_bindsym && current_mode() eq 'default' {
                my @modifiers = %binding<event_state_mask>.permutations.map: *.join: '+';
                my $symbol    = %binding<symbol>;

                next unless @modifiers || $symbol;

                my $binding = do if @modifiers and $symbol {
                    @modifiers X~ "+$symbol";
                } elsif $symbol {
                    $symbol;
                }

                if $binding.any eq $default_bindsym {
                    show_preview 'default';
                }
            }
        }
        whenever Promise.anyof: $sway_mode_subscription.start, (.start with $sway_binding_subscription) {
            done;
        }
        whenever signal(SIGTERM, SIGINT) {
            once {
                put 'Termination request received, terminating processes';

                quit 'main';

                $sway_mode_subscription.kill;
                .kill with $sway_binding_subscription;

                whenever signal($_).zip-latest: Promise.in(5).Supply {
                    put 'Killing processes with SIGKILL';
                    $sway_mode_subscription.kill: SIGKILL;
                    .kill: SIGKILL with $sway_binding_subscription;
                }
            }
        }
    }
}

sub USAGE is export {
    put "$app_title\n";
    put "$app_description\n";

    put $=pod.&get_first_pod('SYNOPSIS').&join_pod_contents_of: Pod::Block::Code, '';
}

sub current_mode returns Str:D {
    with run <swaymsg -t get_binding_state>, :out {
        .out.slurp(:close).&from-json<name>;
    }
}

sub setup_default_mode_key_binding (Str $key_binding) {
    with $key_binding {
        run(«swaymsg -q -- unbindsym --no-repeat --release $_ nop»).so;
        run(«swaymsg -q -- unbindsym --no-repeat $_ nop»).so;
        run(«swaymsg -- bindsym --no-repeat $_ nop»).so;
    }
}

sub preview (Str $mode?,
             Bool :$close     = False,
             Bool :$sort      = False,
             Bool :$add_title = False,
             :@max_rows,
             Int :$ellipsize,
             HorizontalPosition :$ellipsis_position) {
    .get-display-rk.gdk-display-flush with $screen;

    my Bool:D $default_mode = $mode.defined && $mode eq 'default';

    # Close preview window if requested or toggle preview window for default mode and return
    close_preview() && return if $close || ($previewing && $default_mode);

    # Close preview if previewing default mode, but was requested to preview another mode
    close_preview if $previewing && !$default_mode;

    $preview_promise = start {
        $gtk_window = Gnome::Gtk3::Window.new;
        $gtk_window.set-name: 'preview-window';

        once {
            my $window = $gtk_window.get-native-object;

            GtkLayerShell.new: :$window, :init, :layer(LAYER_OVERLAY)
                               :anchors(:EDGE_LEFT, :EDGE_BOTTOM),
                               :margins(:EDGE_BOTTOM(10), :EDGE_LEFT(10));
        }

        my @bindings = do if $mode eq 'default' {
            $sway_config.key_bindings;
        } else {
            $sway_config.mode{$mode}<key_bindings><>;
        }

        @bindings.=sort: *.key if $sort;

        $grid = Gnome::Gtk3::Grid.new;
        $grid.set-name: 'preview-table';

        my Int:D $max_row = do given @max_rows {
            when :so  { .sort(-*).first: * < +@bindings or .min }
            when :not { +@bindings }
        }
        my Int:D $row = $add_title ?? 1 !! 0;
        my Int:D $column = 0;
        for @bindings -> (Str :$key, Hash :value((:$command is copy, :@options))) {
            my Gnome::Gtk3::Label $key_label .= new: :text($key);
            $key_label.set-name:   'key-binding';
            $key_label.set-halign: GTK_ALIGN_START;

            $command.=&ellipsize: $ellipsize, :position($ellipsis_position) if $ellipsize && @bindings > @max_rows.max;

            my Gnome::Gtk3::Label $command_label .= new: :text($command);
            $command_label.set-name:   'command';
            $command_label.set-halign: GTK_ALIGN_START;

            if $row == $max_row {
                $row = $add_title ?? 1 !! 0;
                $column += 2;
            }

            $grid.attach: $key_label,     $column,     $row, 1, 1;
            $grid.attach: $command_label, $column + 1, $row, 1, 1;

            $row++;
        }

        if $add_title {
            my Gnome::Gtk3::Label $mode_name .= new: :text($mode.tclc);
            $mode_name.set-name:   'mode-name';
            $mode_name.set-halign: GTK_ALIGN_FILL;
            $mode_name.set-xalign: 0;

            $grid.attach: $mode_name, 0, 0, $column + 2, 1;
        }

        $gtk_window.add: $grid;

        $main_promise = start { $gtk_window.show-all; $main.main; }
        react {
            whenever $main_promise.Supply.zip-latest: Promise.in(2).Supply {
                done;
            }
        }
    }

    $previewing = True;
}

sub close_preview {
    $previewing = False;

    quit 'preview';

    True;
}

sub quit (Str:D $what) {
    my $promise = $what eq 'preview' ?? $preview_promise !! $main_promise;

    if $promise.defined && $promise.status ~~ Planned {
        .destroy with $gtk_window;

        $main.quit;
    }
}

sub ellipsize (Str:D $string, UInt:D $max_chars, HorizontalPosition :$position = CENTER --> Str:D) {
    if $string.chars > $max_chars {
        do given $position {
            when CENTER {
                given $string {
                    .substr(0, $max_chars ÷ 2).trim ~ ' … ' ~ .substr(.chars - $max_chars ÷ 2, $max_chars).trim;
                }
            }
            when HorizontalPosition::END {
                $string.substr(0, $max_chars).trim ~ ' …';
            }
            when START {
                '… ' ~ $string.substr(* - $max_chars, $max_chars).trim;
            }
        }
    } else {
        $string;
    }
}

# Just in case!
END quit 'main';

=REPOSITORY L<https://github.com/CIAvash/Sway-PreviewKeys>

=BUG L<https://github.com/CIAvash/Sway-PreviewKeys/issues>

=AUTHOR Siavash Askari Nasr - L<https://www.ciavash.name/>

=COPYRIGHT Copyright © 2021 Siavash Askari Nasr

=begin LICENSE
This file is part of Sway::PreviewKeys.

Sway::PreviewKeys is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

Sway::PreviewKeys is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Sway::PreviewKeys.  If not, see <http://www.gnu.org/licenses/>.
=end LICENSE
