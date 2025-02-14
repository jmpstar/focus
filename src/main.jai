main :: () {
    #if DEBUG {
        UA :: #import "Unmapping_Allocator";
        context.allocator = UA.get_unmapping_allocator();

        // OA :: #import "Overwriting_Allocator";
        // context.allocator = OA.get_overwriting_allocator();

    }
    focus_allocator = context.allocator;  // to be used as a default allocator where we need it

    cpu_info = get_cpu_info();

    // Meow hash relies on AES instruction support, so fall back to a standard hash function
    if !check_feature(cpu_info.feature_leaves, x86_Feature_Flag.AES) then calculate_hash = fallback_hash;

    platform_setup();

    // Remember important directories
    config_dir = platform_config_dir();
    data_dir   = platform_data_dir();
    assert(config_dir.count > 0, "Empty config dir");
    assert(!ends_with(config_dir, "/"), "Config dir '%' ends with a '/'. This is a bug.", config_dir);
    assert(data_dir.count > 0, "Empty data dir");
    assert(!ends_with(data_dir, "/"), "Data dir '%' ends with a '/'. This is a bug.", data_dir);
    platform_get_fonts_dir();  // warm-up the fonts dir so that the config highlighter can later use it without heap allocations

    temp_dir     = sprint("%/temp",     data_dir);
    projects_dir = sprint("%/projects", config_dir);
    themes_dir   = sprint("%/themes",   config_dir);

    projects_dir_existed := file_exists(projects_dir);

    if !make_directory_if_it_does_not_exist(projects_dir) then panic_messagebox("Couldn't create folder %. Is the directory writable?", projects_dir);
    if !make_directory_if_it_does_not_exist(temp_dir)     then panic_messagebox("Couldn't create folder % for temporary files. Is the directory writable?", temp_dir);
    if !make_directory_if_it_does_not_exist(themes_dir)   then panic_messagebox("Couldn't create folder % for themes. Is the directory writable?", themes_dir);
    if !projects_dir_existed then write_entire_file(tprint("%/Example Project.focus-config", projects_dir), EXAMPLE_PROJECT_FILE_DATA);

    fill_in_missing_default_themes();

    init_file_watcher();
    init_buffers();
    load_global_config(fallback_to_default_on_failure = true);
    init_workspace();
    init_build_system();

    window_x, window_y, window_width, window_height = platform_get_centered_window_dimensions(config.settings.open_on_the_biggest_monitor);

    window_generic_title = ifx DEBUG then "Focus (debug mode)" else "Focus";
    platform_create_window();

    init_session_with_no_guidance :: () #expand {
        session = maybe_load_previous_session();
        if session.project {
            success := load_project_config(session.project);
            if !success then log_error("Couldn't load project config '%'", session.project);
        }
    }

    args := get_command_line_arguments();

    if args.count >= 2 {
        session_initialized := false;
        for < i: args.count - 1..1 {
            if is_directory(args[i]) {
                if !session_initialized {
                    session = start_fresh_session();
                    session_initialized = true;
                }
                add_directory_to_workspace(args[i], index = 0);
            }
        }
        for i: 1..args.count - 1 {
            if file_exists(args[i]) && !is_directory(args[i]) {
                if !session_initialized {
                    session = start_fresh_session();
                    session_initialized = true;
                }
                editors_open_file(args[i]);
            }
        }
        if !session_initialized init_session_with_no_guidance();
    } else {
        init_session_with_no_guidance();
    }

    // This may generate window resize events if DPI/scaling settings need to be
    // applied, so make sure to only call it after the window is created.
    platform_apply_config();
    Simp.set_color_map(COLOR_MAP);

    #if OS == .MACOS {
        // On macOS, attempting to maximize the window before a frame has been drawn results in a crash, so we delay it until the end of the first frame.
        should_maximize := config.settings.maximize_on_start;
    } else {
        if config.settings.maximize_on_start then platform_maximize_window(window);
    }

    platform_enable_drag_and_drop(window);

    window_width, window_height = Simp.get_render_dimensions(window);
    screen = make_rect(0, 0, window_width, window_height);
    Simp.set_render_target(window);

    // Init logger after we know the session dir and the config
    init_logger();
    defer deinit_logger();  // closes log file handles

    if !check_feature(cpu_info.feature_leaves, x86_Feature_Flag.AES) then log_error("CPU doesn't support AES instructions. A slower hash function will be used.");

    // Requires the session to be created and the configs to be loaded
    start_initial_workspace_scan();

    dpi_scale = platform_get_dpi_scale(window);
    init_fonts_and_dependent_things();
    old_line_height = line_height;

    window_has_focus := true;
    window_resized   := false;

    shift_key: struct {
        last_press:   Time = -1;
        last_release: Time = -1;
        press_count := 0;
    };

    while !should_quit {
        if !redraw_requested platform_wait_message();

        Input.update_window_events();

        if frame_time > MAX_TIME_BEFORE_RESETTING then { init_time(); frame_time = cast(Time) get_time(); }
        current_time := cast(Time) get_time();
        frame_dt   = min(current_time - frame_time, MAX_FRAME_DT);
        frame_time = current_time;

        old_line_height = line_height;
        for Input.get_window_resizes() {
            Simp.update_window(it.window);
            if (it.window == window) {
                should_reinit := dont_ignore_next_window_resize || ((it.width != window_width) || (it.height != window_height));
                window_width = it.width;
                window_height = it.height;
                if should_reinit {
                    // Cleanup: revisit this code, it's been touched by multiple people and needs simplification
                    screen    = make_rect(0, 0, window_width, window_height);
                    dpi_scale = platform_get_dpi_scale(window);
                    init_fonts_and_dependent_things();
                    dont_ignore_next_window_resize = false;
                }
                window_resized = true;
            }
        }

        // Don't do anything when window is resized to a size that's too small
        if window_width < MIN_WINDOW_WIDTH || window_height < MIN_WINDOW_HEIGHT continue;

        update_mouse_state();

        screen_with_title_bar := screen;
        screen_with_title_bar.h += 200;  // should be enough to include the title bar

        #if OS == .MACOS {
            nothing_to_do_this_frame := !redraw_requested && !Input.events_this_frame.count && !mouse.moved_this_frame;

            if !Input.input_application_has_focus && nothing_to_do_this_frame {
                // Avoid changing the cursor when the window is not in Focus, but only when we don't have anything else to
                // do this frame. This also fixes the Cmd+Tab cursor-spawning issue where the window still thinks Cmd is held down.
                sleep_milliseconds(1);
                continue;
            }

            // Try to avoid hot-looping on macOS
            if nothing_to_do_this_frame {
                sleep_milliseconds(1);
                continue;
            }
        }

        redraw_requested = false;
        window_resized   = false;
        dont_scroll_this_frame = false;
        window_has_focus = Input.input_application_has_focus;  // so that we always redraw when the window first loses focus

        workspace_update();
        finder_update();

        for * editor : open_editors {
            using editor;
            cursor_moved = .has_not_moved;
            if old_line_height != line_height {
                // Adjust viewport position
                lines_scrolled := viewport.top / old_line_height;
                viewport.scroll_y.target = xx (lines_scrolled * line_height);
                viewport.top = viewport.scroll_y.target;
            }
        }

        // Keyboard and text input events may be generated for the same keypress.
        // If we handle it as a keyboard event we will need to ignore its text input duplicates
        num_text_input_events_to_ignore := 0;

        for event : Input.events_this_frame {
            if should_quit break;  // don't process any other events we might have in this frame if the previous one set this to true

            // General events
            if event.type == {
                case .QUIT;
                    should_quit = true;

                case .KEYBOARD;
                    // Double shift click
                    if config.settings.double_shift_to_search_in_workspace && event.key_code == .SHIFT {
                        using shift_key;
                        if !event.key_pressed then last_release = frame_time;
                        if event.key_pressed && only_shift_pressed(event.modifier_flags) {
                            if last_press < last_release && press_count > 0 && frame_time - last_press < 0.2 {
                                if finder_is_open() then finder_close();
                                else finder_open_from_editor();
                                press_count = 0;
                            } else {
                                press_count = 1;
                            }
                            last_press = frame_time;
                        }
                        if event.key_pressed then last_press = frame_time;
                    }

                case .MOUSE_V_WHEEL;
                    #if OS != .MACOS {
                        if ctrl_or_cmd_pressed() {
                            if event.wheel_delta < 0  {
                                decrease_font_size();
                                dont_scroll_this_frame = true;
                            } else if event.wheel_delta > 0 {
                                increase_font_size();
                                dont_scroll_this_frame = true;
                            }
                        }
                    }
                case .DRAG_AND_DROP_FILES;
                    editors_handle_file_drop(event.files);
                case .TEXT_INPUT;
                    if num_text_input_events_to_ignore {
                        num_text_input_events_to_ignore -= 1;
                        continue;
                    }
            }

            // Maybe handle a common action that applies to all widgets
            handled := false;

            // Pass events to the active widget.
            // Note that the active widget may change during the frame, so the following events
            // will be sent to the new widget, that's why we check global widget for each event.
            if #complete active_global_widget == {
                case .editors;                  handled = editors_handle_event(event);
                case .finder;                   handled = finder_handle_event(event);
                case .open_file_dialog;         handled = open_file_dialog_handle_event(event);
                case .delete_file_dialog;       handled = delete_file_dialog_handle_event(event);
                case .go_to_line_dialog;        handled = go_to_line_dialog_handle_event(event);
                case .open_project_dialog;      handled = open_project_dialog_handle_event(event);
                case .unsaved_buffers_dialog;   handled = unsaved_buffers_dialog_handle_event(event);
                case .confirm_overwrite_dialog; handled = confirm_overwrite_dialog_handle_event(event);
                case .commands_dialog;          handled = commands_dialog_handle_event(event);
                case .theme_dialog;             handled = theme_dialog_handle_event(event);
            }

            if !handled {
                action := map_event_to_action(event, Action_Editors);
                handled = handle_common_editor_action(action);
            }
            if !handled then handled = maybe_execute_a_build_command(event);

            if handled && event.type == .KEYBOARD then num_text_input_events_to_ignore = event.text_input_count;

            key_sequence_input_process_event(event, handled);
        }

        if should_quit && unsaved_buffers_exist() && !force_quit {
            show_unsaved_buffers_dialog();
            should_quit = false;
        }

        process_buffer_save_queue();
        build_system_update();
        maybe_revert_temporary_theme();
        refresh_open_buffers();

        draw_frame();

        pointer_end_frame();

        // TODO:
        // maybe_save_editor_state_into_session();

        maybe_save_editor_history();

        if should_reload_workspace {
            hard_reload_workspace();
            should_reload_workspace = false;
            redraw_requested = true;
        }

        reset_temporary_storage();

        #if OS == .MACOS {
            if should_maximize {
                should_maximize = false;
                platform_maximize_window(window);
            }
        }

        // #if DEBUG FrameMark();

        if cast(Time) get_time() - frame_time <= QUICK_FRAME_DT {
            // It should be ok to sleep a bit after a quick frame to avoid pegging the core.
            sleep_milliseconds(2);
        }
    }

    // report := make_leak_report();
    // log_leak_report(report);
}

handle_common_editor_action :: (action: Action_Editors, placement: Editor_Placement = .in_place) -> handled: bool {
    if action == {
        case .quit;                                             should_quit = true;                                 return true;

        case .increase_font_size;                               increase_font_size();                               return true;
        case .decrease_font_size;                               decrease_font_size();                               return true;
        case .reset_font_size_to_default;                       reset_font_size_to_default();                       return true;

        case .open_project;                                     #through;
        case .switch_to_project;                                show_dialog(*open_project_dialog);                  return true;
        case .close_project;                                    close_project();                                    return true;

        case .choose_theme;                                     show_dialog(*theme_dialog);                         return true;
        case .edit_current_theme;                               edit_current_theme(placement);                      return true;

        case .open_projects_directory;                          platform_open_in_explorer(projects_dir);            return true;
        case .open_global_config;                               editors_open_global_config(placement);              return true;
        case .open_project_config;                              editors_open_project_config(placement);             return true;
        case .show_default_config;                              editors_show_default_config(placement);             return true;
        case .show_troubleshooting_info;                        editors_show_troubleshooting_info(placement);       return true;

        case .go_to_line;                                       show_go_to_line_dialog();                           return true;
        case .create_new_file;                                  editors_create_new_file(placement);                 return true;
        case .create_new_file_on_the_side;                      editors_create_new_file(.on_the_side);              return true;

        case .open_file_by_name;                                show_open_file_dialog(.search);                     return true;
        case .navigate_to_file;                                 show_open_file_dialog(.navigate);                   return true;
        case .navigate_to_file_from_root;                       show_open_file_dialog(.navigate, from_root = true); return true;
        case .switch_between_open_files;                        show_open_file_dialog(.open_editors);               return true;

        case .show_commands;                                    show_dialog(*commands_dialog);                      return true;
        case .toggle_fullscreen;                                editor_toggle_fullscreen();                         return true;

        case .move_to_previous_editor_history;                  move_to_previous_editor_history();                  return true;
        case .move_to_next_editor_history;                      move_to_next_editor_history();                      return true;

        case .move_to_previous_buffer;                          move_to_previous_editor_history(by_buffer = true);  return true;
        case .move_to_next_buffer;                              move_to_next_editor_history    (by_buffer = true);  return true;

        case .toggle_build_panel;                               toggle_build_panel();                               return true;

        case .build_kill_running_command;                       build_kill_running_command();                       return true;

        // TODO: search_in_buffer
        case .search_in_project;
            if active_global_widget == .editors then finder_open_from_editor(); else finder_open();                 return true;
    }
    return false;
}

maybe_execute_a_build_command :: (event: Input.Event) -> handled: bool {
    action := map_event_to_action(event, Action_Build);
    if action == INVALID_KEYMAP_ACTION return false;

    command_id := cast(s64) action;
    assert(command_id <= config.build.commands.count, "A keymap was bound to a nonexistent build command %. Number of build commands: %. This is a bug", command_id, config.build.commands.count);

    command := ifx command_id > 0 then *config.build.commands[command_id-1] else *config.build.defaults;
    execute_build_command(command);

    return true;
}

init_fonts_and_dependent_things :: () {
    push_allocator(focus_allocator);  // we sometimes call this from within a temp allocator

    font_size = clamp(font_size, MIN_FONT_SIZE, MAX_FONT_SIZE);
    delta := font_size - DEFAULT_FONT_SIZE;
    font_ui_size            = clamp(DEFAULT_FONT_UI_SIZE            + delta, MIN_FONT_SIZE, MAX_FONT_SIZE);
    font_ui_big_size        = clamp(DEFAULT_FONT_UI_BIG_SIZE        + delta, MIN_FONT_SIZE, MAX_FONT_SIZE);
    font_ui_medium_size     = clamp(DEFAULT_FONT_UI_MEDIUM_SIZE     + delta, MIN_FONT_SIZE, MAX_FONT_SIZE);
    font_ui_small_size      = clamp(DEFAULT_FONT_UI_SMALL_SIZE      + delta, MIN_FONT_SIZE, MAX_FONT_SIZE);
    font_ui_very_small_size = clamp(DEFAULT_FONT_UI_VERY_SMALL_SIZE + delta, MIN_FONT_SIZE, MAX_FONT_SIZE);
    font_icons_size         = clamp(DEFAULT_FONT_ICONS_SIZE         + delta, MIN_FONT_SIZE, MAX_FONT_SIZE);
    font_icons_small_size   = clamp(DEFAULT_FONT_ICONS_SMALL_SIZE   + delta, MIN_FONT_SIZE, MAX_FONT_SIZE);
    font_icons_tiny_size    = clamp(DEFAULT_FONT_ICONS_TINY_SIZE    + delta, MIN_FONT_SIZE, MAX_FONT_SIZE);

    font = Simp.get_font_at_size(main_font_name, main_font_data, cast(int) (font_size * dpi_scale));
    assert(font != null, "Couldn't init main text font\n");

    font_ui = Simp.get_font_at_size(FONT_UI.name, FONT_UI.data, cast(int) (font_ui_size * dpi_scale));
    assert(font_ui != null, "Couldn't init main ui font\n");
    font_ui_line_height = cast(float) font_ui.default_line_spacing;

    font_ui_big = Simp.get_font_at_size(FONT_UI.name, FONT_UI.data, cast(int) (font_ui_big_size * dpi_scale));
    assert(font_ui_big != null, "Couldn't init big ui font\n");
    font_ui_big_line_height = cast(float) font_ui_big.default_line_spacing;

    font_ui_medium = Simp.get_font_at_size(FONT_UI.name, FONT_UI.data, cast(int) (font_ui_medium_size * dpi_scale));
    assert(font_ui_medium != null, "Couldn't init medium ui font\n");
    font_ui_medium_line_height = cast(float) font_ui_medium.default_line_spacing;

    font_ui_bold = Simp.get_font_at_size(FONT_UI_BOLD.name, FONT_UI_BOLD.data, cast(int) (font_ui_size * dpi_scale));
    assert(font_ui_bold != null, "Couldn't init bold ui font\n");

    font_ui_small = Simp.get_font_at_size(FONT_UI.name, FONT_UI.data, cast(int) (font_ui_small_size * dpi_scale));
    assert(font_ui_small != null, "Couldn't init small ui font\n");

    font_ui_very_small = Simp.get_font_at_size(FONT_UI.name, FONT_UI.data, cast(int) (font_ui_very_small_size * dpi_scale));
    assert(font_ui_very_small != null, "Couldn't init small ui font\n");

    font_icons = Simp.get_font_at_size(FONT_ICONS.name, FONT_ICONS.data, cast(int) (font_icons_size * dpi_scale));
    assert(font_icons != null, "Couldn't init main icon font\n");

    font_icons_small = Simp.get_font_at_size(FONT_ICONS.name, FONT_ICONS.data, cast(int) (font_icons_small_size * dpi_scale));
    assert(font_icons_small != null, "Couldn't init main icon font\n");

    font_icons_tiny = Simp.get_font_at_size(FONT_ICONS.name, FONT_ICONS.data, cast(int) (font_icons_tiny_size * dpi_scale));
    assert(font_icons_tiny != null, "Couldn't init tiny icon font\n");

    // WORKAROUND:
    // Make a dummy call with most common chars for each font so that
    // we have all the font atlases loaded in the GPU memory once
    // (TODO: maybe there's an easy way for Simp to only update textures on flush?)
    COMMON_CHARS :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789… ~!@#$%^&*()-|\"':;_+={}[]\\/`,.<>?АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчщъыьэюя¶•";
    Simp.prepare_text(font,             COMMON_CHARS);
    Simp.prepare_text(font_ui,          COMMON_CHARS);
    Simp.prepare_text(font_ui_bold,     COMMON_CHARS);
    Simp.prepare_text(font_ui_small,    COMMON_CHARS);
    Simp.prepare_text(font_ui_big,      COMMON_CHARS);
    Simp.prepare_text(font_ui_medium,   COMMON_CHARS);

    common_icons: String_Builder;
    common_icons.allocator = temp;
    for enum_values_as_enum(Icon) {
        char := convert_utf32_to_utf8(xx it);
        append(*common_icons, to_string(*char));
    }
    append(*common_icons, PEN_ICON);
    append(*common_icons, XMARK_ICON);
    icons_string := builder_to_string(*common_icons, allocator = temp);

    Simp.prepare_text(font_icons,       icons_string);
    Simp.prepare_text(font_icons_tiny, icons_string);

    // Things that depend on char size
    char_size       = cast(float) font.em_width;
    char_x_advance  = cast(float) font.x_advance;
    old_line_height = line_height;
    line_height     = floor(cast(float) font.default_line_spacing * cast(float)config.settings.line_height_scale_percent / 100.0);
    scrollbar_size  = floor(1.5 * char_size);
    rounding_radius = floor(char_size / 2);
    rounding_radius_large = floor(char_size / 1.5);
    rounding_radius_small = floor(char_size / 3);
}

update_mouse_state :: () {
    x, y := get_mouse_pointer_position(window, false);
    mouse.pointer.x = xx x;
    mouse.pointer.y = xx (window_height - y);
    mouse.moved_this_frame = (mouse.pointer != mouse.previous_position);
    if mouse.moved_this_frame {
        platform_show_cursor(true);
    }
    mouse.previous_position = mouse.pointer;

    if shift_pressed() {
        mouse.scroll_x_delta = cast(s32) (cast(float) Input.mouse_wheel_delta.vertical * WHEEL_SENSITIVITY);
    } else {
        mouse.scroll_x_delta = cast(s32) (cast(float) Input.mouse_wheel_delta.horizontal * WHEEL_SENSITIVITY);
        mouse.scroll_y_delta = cast(s32) (cast(float) Input.mouse_wheel_delta.vertical   * WHEEL_SENSITIVITY);
    }
    mouse.smooth_scroll = (mouse.scroll_y_delta % 120) == 0;  // @Robustness: hard-coded typical delta, but it really should be ok for now
    if !config.settings.smooth_scrolling then mouse.smooth_scroll = false;

    update_button :: (button: *Mouse_Button_State, key: Input.Key_Code) {
        button.is_down       = key_state(key) & .DOWN  != 0;  // NOTE: this doesn't include just_pressed!
        button.just_pressed  = key_state(key) & .START != 0;
        button.just_released = key_state(key) & .END   != 0;

        if button.just_pressed {
            time_from_last_click := frame_time - button.last_down_time;
            time_from_last_double_click := frame_time - button.last_double_click_time;
            distance_from_last_click := mouse.pointer - button.last_down_pos;
            max_distance := max(abs(distance_from_last_click.x), abs(distance_from_last_click.y));
            button.last_down_pos  = mouse.pointer;
            button.last_down_time = frame_time;
            button.just_double_clicked = time_from_last_click < DOUBLE_CLICK_SPEED && max_distance < DOUBLE_CLICK_TOLERANCE;
            button.just_triple_clicked = time_from_last_double_click < DOUBLE_CLICK_SPEED && max_distance < DOUBLE_CLICK_TOLERANCE;
            if button.just_triple_clicked then button.just_double_clicked = false;  // exclusive
            if button.just_double_clicked {
                button.last_double_click_time = frame_time;
            }
        } else {
            button.just_double_clicked = false;
            button.just_triple_clicked = false;
        }

        button.is_dragging = button.is_down && mouse.pointer != button.last_down_pos;
    }

    update_button(*mouse.left,   .MOUSE_BUTTON_LEFT);
    update_button(*mouse.right,  .MOUSE_BUTTON_RIGHT);
    update_button(*mouse.middle, .MOUSE_BUTTON_MIDDLE);
}

editor_toggle_fullscreen :: () {
    fullscreen = !fullscreen;
    toggle_fullscreen(window, fullscreen, *fullscreen_state);  // platform-specific
}

increase_font_size :: () {
    if (font_size + 1) <= MAX_FONT_SIZE {
        font_size += 1;
        init_fonts_and_dependent_things();
    }
}

decrease_font_size :: () {
    if (font_size - 1) >= MIN_FONT_SIZE {
        font_size -= 1;
        init_fonts_and_dependent_things();
    }
}

reset_font_size_to_default :: () {
    font_size = default_font_size;
    init_fonts_and_dependent_things();
}

panic :: (format_string: string, args: .. Any, exit_code : s32 = 1) {
    log_error(format_string, ..args);
    exit(exit_code);
} @PrintLike

panic_messagebox :: (format_string: string, args: .. Any) {
    #if OS == .WINDOWS {
        message := tprint(format_string, ..args);
        MessageBoxW(null, utf8_to_wide(message), utf8_to_wide("Fatal Error"), MB_OK);
        exit(1);
    } else {
        panic(format_string, ..args);
    }
} @PrintLike

unimplemented :: (loc := #caller_location) {
    print("!!!! Unimplemented at %\n", loc);
}

key_state :: inline (key: Input.Key_Code) -> Input.Key_Current_State {
    return Input.input_button_states[key];
}

shift_pressed :: inline () -> bool {
    return key_state(.SHIFT) & .DOWN != 0;
}

only_shift_pressed :: inline (mods: Mods) -> bool {
    return mods.packed == MODS_SHIFT;
}

ctrl_or_cmd_pressed :: inline () -> bool {
    #if OS != .MACOS {
        return key_state(.CTRL) & .DOWN != 0;
    } else {
        return key_state(.CMD) & .DOWN != 0;
    }
}

update_window_size :: (w: s64, h: s64) {
    window_width  = w;
    window_height = h;
    Simp.update_window(window);
    screen = make_rect(0, 0, window_width, window_height);
    new_dpi_scale := platform_get_dpi_scale(window);
    if new_dpi_scale != dpi_scale {
        dpi_scale = new_dpi_scale;
        init_fonts_and_dependent_things();
    }
}

current_time_consensus_backwards_compatible :: () -> Apollo_Time {
    #if WINDOWS7 {
        #assert OS == .WINDOWS;
        // GetSystemTimePreciseAsFileTime is only supported in Windows 8+
        // and that's what Apollo_Time uses.
        // TODO: remove when we drop support for Windows 7
        ft_now: FILETIME;
        GetSystemTimeAsFileTime(*ft_now);

        apollo := filetime_to_apollo(ft_now);
        return apollo;
    } else {
        return current_time_consensus();
    }
}

fill_in_missing_default_themes :: () {
    for theme : BUILTIN_THEMES {
        theme_file := tprint("%/%.focus-theme", themes_dir, theme.name);
        if !file_exists(theme_file) then write_entire_file(theme_file, theme.contents);
    }
}

calculate_hash: (bytes: [] u8) -> u64 = calculate_meow_hash;

// Important directories
config_dir:   string;
data_dir:     string;
temp_dir:     string;
projects_dir: string;
themes_dir:   string;

window: Window_Type;
window_generic_title: string = ---;
window_width  := 0;
window_height := 0;
window_x  := -1;
window_y  := -1;
dpi_scale := 1.0;

fullscreen: bool;
fullscreen_state: Saved_Window_Info;

redraw_requested        := true;  // set to true to render the first frame
should_quit             := false;
force_quit              := false;
should_reload_workspace := false;
automatic_workspace_reload := false;

frame_time: Time;                 // ever-increasing time since start in seconds
frame_dt:   Time = MAX_FRAME_DT;  // time delta since the last frame
MAX_FRAME_DT:   Time : xx (1.0 / 60);
QUICK_FRAME_DT: Time : xx (1.0 / 300);  // sorry 300Hz monitor users
MAX_TIME_BEFORE_RESETTING: Time : xx (60 * 60 * 24 * 7);  // reset timer after a week to avoid losing timer precision

EDIT_GROUP_TIMEOUT :: 0.3;  // for undo/redo

screen: Rect;  // contains the current working area rect for convenience

mouse: Mouse_State;

Mouse_State :: struct {
    pointer: Vector2;
    previous_position: Vector2;
    moved_this_frame: bool;
    scroll_x_delta: s32;
    scroll_y_delta: s32;
    smooth_scroll: bool;

    left:   Mouse_Button_State;
    right:  Mouse_Button_State;
    middle: Mouse_Button_State;
}

Mouse_Button_State :: struct {
    is_down:             bool;
    is_dragging:         bool;
    just_pressed:        bool;
    just_released:       bool;
    just_double_clicked: bool;
    just_triple_clicked: bool;

    last_down_pos:  Vector2;
    last_down_time: Time;
    last_double_click_time: Time;
}

WHEEL_SENSITIVITY :: 1.0;

PEN_ICON            :: #run to_string(*convert_utf32_to_utf8(0xf304));
CASE_SENSITIVE_ICON :: #run to_string(*convert_utf32_to_utf8(0xf031));
WHOLE_WORD_ICON     :: #run to_string(*convert_utf32_to_utf8(0xe4ba));
REGEX_SEARCH_ICON   :: #run to_string(*convert_utf32_to_utf8(0xf621));
BULLET_ICON         :: #run to_string(*convert_utf32_to_utf8(0x2022));
XMARK_ICON          :: #run to_string(*convert_utf32_to_utf8(0xf057));

TAB_SIZE: s32 = 4;

font:               *Simp.Dynamic_Font;
font_ui:            *Simp.Dynamic_Font;
font_ui_bold:       *Simp.Dynamic_Font;
font_ui_big:        *Simp.Dynamic_Font;
font_ui_small:      *Simp.Dynamic_Font;
font_ui_very_small: *Simp.Dynamic_Font;
font_ui_medium:     *Simp.Dynamic_Font;
font_icons:         *Simp.Dynamic_Font;
font_icons_small:   *Simp.Dynamic_Font;
font_icons_tiny:    *Simp.Dynamic_Font;

DEFAULT_FONT_SIZE               :: 14;
DEFAULT_FONT_UI_SIZE            :: 15;
DEFAULT_FONT_UI_BIG_SIZE        :: 28;
DEFAULT_FONT_UI_MEDIUM_SIZE     :: 18;
DEFAULT_FONT_UI_SMALL_SIZE      :: 14;
DEFAULT_FONT_UI_VERY_SMALL_SIZE :: 12;
DEFAULT_FONT_ICONS_SIZE         :: 16;
DEFAULT_FONT_ICONS_SMALL_SIZE   :: 12;
DEFAULT_FONT_ICONS_TINY_SIZE    :: 8;

main_font_name := "default";
main_font_data := #run FONT.data;

default_font_size       := DEFAULT_FONT_SIZE;  // can be changed in the config

font_size               := DEFAULT_FONT_SIZE;  // when changing font size, we change just this one and then derive the other ones from it
font_ui_size            := DEFAULT_FONT_UI_SIZE;
font_ui_big_size        := DEFAULT_FONT_UI_BIG_SIZE;
font_ui_medium_size     := DEFAULT_FONT_UI_MEDIUM_SIZE;
font_ui_small_size      := DEFAULT_FONT_UI_SMALL_SIZE;
font_ui_very_small_size := DEFAULT_FONT_UI_VERY_SMALL_SIZE;
font_icons_size         := DEFAULT_FONT_ICONS_SIZE;
font_icons_small_size   := DEFAULT_FONT_ICONS_SMALL_SIZE;
font_icons_tiny_size    := DEFAULT_FONT_ICONS_TINY_SIZE;

// Depend on font size
char_size:                  float;
char_x_advance:             float;
line_height:                float;
old_line_height:            float;  // to track font changes
font_ui_line_height:        float;
font_ui_big_line_height:    float;
font_ui_medium_line_height: float;
rounding_radius:            float;
rounding_radius_large:      float;
rounding_radius_small:      float;
scrollbar_size:             float;

dont_scroll_this_frame := false;  // because e.g. a mouse wheel event has been handled

Mods :: Input.Event.Modifier_Flags;

Time :: #type,isa float64;

project_dirs: [..] Project_Dir;

active_global_widget: Active_Global_Widget = .editors;

Active_Global_Widget :: enum {
    editors;
    finder;
    open_file_dialog;
    delete_file_dialog;
    go_to_line_dialog;
    commands_dialog;
    open_project_dialog;
    unsaved_buffers_dialog;
    confirm_overwrite_dialog;
    theme_dialog;
}

Project_Dir :: struct {
    path: string;          // e.g. "C:/projects/focus"
    path_prefix_len: s64;  // in this case the length of "C:/projects/"
    name: string;          // a view into path
}

Builtin_Theme :: struct {
    name: string;
    contents: string;
}

BUILTIN_THEMES :: #run -> [] Builtin_Theme {
    themes: [..] Builtin_Theme;

    visitor :: (info: *File_Visit_Info, themes: *[..] Builtin_Theme) {
        full_path := info.full_name;
        path, basename, extension, name := path_decomp(full_path);
        if extension != "focus-theme" return;
        file_contents, success := read_entire_file(full_path);
        if !success return;
        array_add(themes, Builtin_Theme.{ name = basename, contents = file_contents });
    }
    visit_files("config/themes", recursive = false, *themes, visitor, visit_files = true, visit_directories = false);

    return themes;
}

// A string which contains the path to a file which was just drag-and-dropped into the editor (for the draw code to use)
just_dropped_file := "";

cpu_info: Cpu_X86;

focus_allocator: Allocator;

// This will be set to `true` in `refresh_config()` to signal that the
// next window resize event should be handled even if the window doesn't actually
// change size. This is needed when changing DPI/scaling options which require
// a full repaint.
dont_ignore_next_window_resize := false;


#load "layout.jai";
#load "editors.jai";
#load "buffer.jai";
#load "build_system.jai";
#load "unicode.jai";
#load "draw.jai";
#load "pointer_image.jai";
#load "utils.jai";
#load "files.jai";
#load "workspace.jai";
#load "config.jai";
#load "config_parser.jai";
#load "config_migrator.jai";
#load "colors.jai";
#load "keymap.jai";
#load "session.jai";
#load "meow_hash.jai";
#load "user_messages.jai";

#load "widgets/generic_choice_dialog.jai";
#load "widgets/text_input.jai";
#load "widgets/open_file_dialog.jai";
#load "widgets/delete_file_dialog.jai";
#load "widgets/go_to_line_dialog.jai";
#load "widgets/finder.jai";
#load "widgets/unsaved_buffers.jai";
#load "widgets/commands.jai";
#load "widgets/open_project.jai";
#load "widgets/confirm_overwrite.jai";
#load "widgets/theme_dialog.jai";

#load "langs/common.jai";
#load "langs/jai.jai";
#load "langs/c.jai";
#load "langs/csharp.jai";
#load "langs/focus_config.jai";
#load "langs/glsl.jai";
#load "langs/golang.jai";
#load "langs/lua.jai";
#load "langs/odin.jai";
#load "langs/python.jai";
#load "langs/renpy.jai";
#load "langs/xml.jai";
#load "langs/worklog.jai";
#load "langs/yang.jai";

#if OS == .WINDOWS {
    #load "platform/windows.jai";
    #import "Windows_Utf8";
} else #if OS == .LINUX {
    #load "platform/linux.jai";
} else #if OS == .MACOS {
    #load "platform/macos.jai";
} else {
    #assert false, "Unsupported OS";
}

/*
 * Idealy this would go under `#if OS == .LINUX`. However, that doesn't work at the moment,
 * compilation fails with the following error:
 *
 *   Error: Cannot designate program parameters for the module "Linux_Display" because an import for that module has already been seen, so it's too late.
 *
 * This seems to happen because imports placed inside of an `#if` are processed after top-level
 * imports, and `Linux_Display` is pulled-in by other modules (`Clipboard`, `Input`, `Simp`) that
 * the editor imports at the top level. Not sure if this is a compiler bug or if it's working as
 * intended, pretty hard to say considering evaluation order is not guaranteed in any way.
 *
 * `Linux_Display` is empty on platforms other than Linux, so importing it should be basically
 * free on Windows/MacOS.
 */
_ :: #import "Linux_Display"()(VALIDATE_USAGE = DEBUG);

#import "Atomics";
#import "Basic"()(MEMORY_DEBUGGER = DEBUG);
#import "Compiler";
#import "File";
#import "File_Utilities";
#import "File_Watcher";
#import "Flat_Pool";
#import "Math";
#import "Machine_X64";
#import "Process";
#import "Reflection";
#import "Sloppy_Math";
#import "System";
#import "String";
#import "Sort";
#import "Simple_Bucket_Array";
#import "Thread";
#import "Unicode";
#import "Window_Creation";

re :: #import "uniform";

// NOTE to future self: remove `.NeverCapture` from `BASE_REGEX_FLAGS` if we ever want to have
//                      find-and-replace with regex capture support
BASE_REGEX_FLAGS : re.ParseFlags : (.LikePerl | .NeverCapture) & ~.OneLine;

// #if DEBUG {
//     #import "Tracy";
// }

File_Async :: #import "File_Async";

Simp  :: #import "Simp";
Input :: #import "Input";

MAX_BUFFER_SIZE_FOR_HIGHLIGHTS :: 5 * 1024 * 1024;

#scope_file

MODS_NONE           :: #run Mods.{}.packed;
MODS_CTRL           :: #run Mods.{ ctrl_pressed  = true }.packed;
MODS_ALT            :: #run Mods.{ alt_pressed   = true }.packed;
MODS_SHIFT          :: #run Mods.{ shift_pressed = true }.packed;
MODS_ALT_SHIFT      :: #run Mods.{ alt_pressed  = true, shift_pressed = true }.packed;
MODS_CTRL_SHIFT     :: #run Mods.{ ctrl_pressed = true, shift_pressed = true }.packed;
MODS_CTRL_ALT       :: #run Mods.{ ctrl_pressed = true, alt_pressed   = true }.packed;
MODS_CTRL_ALT_SHIFT :: #run Mods.{ ctrl_pressed = true, alt_pressed   = true, shift_pressed = true }.packed;


#scope_export

MIN_WINDOW_WIDTH  :: 100;
MIN_WINDOW_HEIGHT :: 100;

DOUBLE_CLICK_SPEED     :: 0.3;  // how many seconds between clicks to consider it a double click
DOUBLE_CLICK_TOLERANCE :: 2;    // how many pixels between the click locations are allowed

// Embed default fonts
FONT         :: #run load_font("FiraCode-Retina.ttf");
FONT_UI      :: #run load_font("OpenSans-Regular.ttf");
FONT_UI_BOLD :: #run load_font("OpenSans-SemiBold.ttf");
FONT_ICONS   :: #run load_font("font-awesome/Font Awesome 6 Free-Solid-900.otf");

MIN_FONT_SIZE :: 4;
MAX_FONT_SIZE :: 30;  // setting a larger size has caused freetype to crash - not sure yet why.
                      // Probably we don't give it enough memory for a glyph bitmap when rendering it?

load_font :: (name: string) -> Embedded_Font {
    path := tprint("fonts/%", name);
    data, success := read_entire_file(path);
    assert(success, "Couldn't load font '%'", path);

    return Embedded_Font.{ name = name, data = data};
}

Embedded_Font :: struct {
    name: string;
    data: string;
}

DEBUG_FILE_REFRESH :: false;  // TODO: remove when done debugging
