obs = obslua
ffi = require("ffi")

-- Global variables
source_name = ""
scene_name = ""
sensitivity = 1.0
center_offset_x = 0
center_offset_y = 0
enabled = false
last_mouse_x = 0
last_mouse_y = 0
update_interval = 0.05  -- update every 50ms instead of every frame
time_since_last_update = 0
debug_mode = true -- Enable debug logging
hotkey_id = obs.OBS_INVALID_HOTKEY_ID -- Store the hotkey ID
calibrate_hotkey_id = obs.OBS_INVALID_HOTKEY_ID -- Hotkey for calibration
base_pos_x = nil -- Initial X position of the source
screen_center_x = nil -- Center X of the screen
initial_mouse_x = nil -- Mouse X position at calibration
tracking_area_width = 80.0  -- Default tracking area width (percentage of screen)

-- Idle tracking variables
cursor_idle_delay = 0.5  -- Default: wait 0.5 seconds after cursor stops moving
cursor_last_moved_time = 0  -- Time when cursor last moved
cursor_target_position = nil  -- Where the source should move to after delay
cursor_is_idle = false  -- Whether cursor is currently idle

-- Animation variables
animation_in_progress = false
animation_start_pos = nil
animation_target_pos = nil
animation_progress = 0
animation_duration = 0.3  -- How long the animation takes in seconds

-- Debug logging function
function debug_log(message)
    if debug_mode then
        print("[Cursor Tracker] " .. message)
    end
end

-- FFI declarations for mouse position tracking
if ffi.os == "Windows" then
    ffi.cdef[[
        typedef struct {
            long x;
            long y;
        } POINT;
        int GetCursorPos(POINT* lpPoint);
    ]]
    point = ffi.new("POINT")
elseif ffi.os == "OSX" then
    -- MacOS declarations
    ffi.cdef[[
        typedef struct CGPoint {
            double x;
            double y;
        } CGPoint;
        CGPoint CGEventGetLocation(void *event);
        void *CGEventCreate(void *source);
        void CFRelease(void *cf);
    ]]
elseif ffi.os == "Linux" then
    -- Basic X11 support
    ffi.cdef[[
        typedef struct {
            void *display;
            unsigned long root;
            unsigned long window;
            int root_x, root_y;
            int win_x, win_y;
            unsigned int mask;
        } XQueryPointerReply;
        
        void *XOpenDisplay(const char *display_name);
        int XQueryPointer(void *display, unsigned long window, 
                          unsigned long *root_return, unsigned long *child_return,
                          int *root_x_return, int *root_y_return,
                          int *win_x_return, int *win_y_return,
                          unsigned int *mask_return);
        unsigned long XDefaultRootWindow(void *display);
        void XCloseDisplay(void *display);
    ]]
end

-- Function to define script properties
function script_properties()
    local props = obs.obs_properties_create()
    
    -- Add enable/disable control
    obs.obs_properties_add_bool(props, "enabled", "Enable Cursor Tracking")
    
    -- Create dropdown list for sources
    local source_list = obs.obs_properties_add_list(props, "source_name", "Screen Capture Source", 
                                                  obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    
    -- Add empty option
    obs.obs_property_list_add_string(source_list, "Select a source", "")
    
    -- Get all sources and add them to the list
    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, source in ipairs(sources) do
            local name = obs.obs_source_get_name(source)
            obs.obs_property_list_add_string(source_list, name, name)
        end
        obs.source_list_release(sources)
    end
    
    -- Create dropdown list for scenes
    local scene_list = obs.obs_properties_add_list(props, "scene_name", "Scene", 
                                                 obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    
    -- Add empty option for current scene
    obs.obs_property_list_add_string(scene_list, "Current Scene", "")
    
    -- Get all scenes and add them to the list
    local scenes = obs.obs_frontend_get_scenes()
    if scenes ~= nil then
        for _, scene in ipairs(scenes) do
            local name = obs.obs_source_get_name(scene)
            obs.obs_property_list_add_string(scene_list, name, name)
        end
        obs.source_list_release(scenes)
    end
    
    -- Keep the other properties
    obs.obs_properties_add_float_slider(props, "sensitivity", "Movement Sensitivity", 0.1, 3.0, 0.1)
    obs.obs_properties_add_int_slider(props, "center_offset_x", "Center Offset X", -500, 500, 1)
    obs.obs_properties_add_int_slider(props, "center_offset_y", "Center Offset Y", -500, 500, 1)
    obs.obs_properties_add_float_slider(props, "update_interval", "Update Interval (seconds)", 0.01, 0.5, 0.01)
    obs.obs_properties_add_float_slider(props, "cursor_idle_delay", "Movement Delay (seconds)", 0.0, 3.0, 0.1)
    obs.obs_properties_add_float_slider(props, "animation_duration", "Transition Duration (seconds)", 0.0, 2.0, 0.1)
    obs.obs_properties_add_float_slider(props, "tracking_area_width", "Tracking Area Width (%)", 10.0, 100.0, 5.0)
    
    return props
end

-- Function to update script settings
function script_update(settings)
    source_name = obs.obs_data_get_string(settings, "source_name")
    scene_name = obs.obs_data_get_string(settings, "scene_name")
    sensitivity = obs.obs_data_get_double(settings, "sensitivity")
    center_offset_x = obs.obs_data_get_int(settings, "center_offset_x")
    center_offset_y = obs.obs_data_get_int(settings, "center_offset_y")
    enabled = obs.obs_data_get_bool(settings, "enabled")
    update_interval = obs.obs_data_get_double(settings, "update_interval")
    cursor_idle_delay = obs.obs_data_get_double(settings, "cursor_idle_delay")
    animation_duration = obs.obs_data_get_double(settings, "animation_duration")
    tracking_area_width = obs.obs_data_get_double(settings, "tracking_area_width")
    
    -- Reset timer
    time_since_last_update = update_interval
    
    debug_log("Settings updated - Enabled: " .. tostring(enabled) .. 
              ", Source: " .. source_name .. 
              ", Scene: " .. scene_name .. 
              ", Sensitivity: " .. tostring(sensitivity) ..
              ", Idle delay: " .. tostring(cursor_idle_delay) ..
              ", Animation duration: " .. tostring(animation_duration) ..
              ", Tracking area width: " .. tostring(tracking_area_width) .. "%")
end

-- Function to get the current mouse position
function get_mouse_position()
    local mouse = { x = 0, y = 0 }
    
    if ffi.os == "Windows" then
        if ffi.C.GetCursorPos(point) ~= 0 then
            mouse.x = point.x
            mouse.y = point.y
        end
    elseif ffi.os == "OSX" then
        local event = ffi.C.CGEventCreate(nil)
        if event ~= nil then
            local position = ffi.C.CGEventGetLocation(event)
            mouse.x = position.x
            mouse.y = position.y
            ffi.C.CFRelease(event)
            -- Debug mouse position
            if debug_mode and math.random(1, 100) == 1 then -- Only log occasionally to avoid spam
                debug_log("Mouse position: " .. mouse.x .. ", " .. mouse.y)
            end
        else
            debug_log("Failed to create CGEvent")
        end
    elseif ffi.os == "Linux" then
        local display = ffi.C.XOpenDisplay(nil)
        if display ~= nil then
            local root = ffi.C.XDefaultRootWindow(display)
            local root_return = ffi.new("unsigned long[1]")
            local child_return = ffi.new("unsigned long[1]")
            local root_x = ffi.new("int[1]")
            local root_y = ffi.new("int[1]")
            local win_x = ffi.new("int[1]")
            local win_y = ffi.new("int[1]")
            local mask = ffi.new("unsigned int[1]")
            
            if ffi.C.XQueryPointer(display, root, root_return, child_return,
                                  root_x, root_y, win_x, win_y, mask) ~= 0 then
                mouse.x = root_x[0]
                mouse.y = root_y[0]
            end
            ffi.C.XCloseDisplay(display)
        end
    end
    
    return mouse
end

-- Function to move the source based on mouse position
function move_source()
    -- Exit if disabled or no source selected
    if not enabled then 
        return 
    end
    
    if source_name == "" then
        debug_log("No source selected")
        return
    end
    
    -- Ensure we have calibrated values
    if base_pos_x == nil or screen_center_x == nil or initial_mouse_x == nil then
        debug_log("Calibrating first...")
        calibrate_position(true)
        return
    end
    
    -- Get mouse position
    local mouse_pos = get_mouse_position()
    
    -- Check if mouse has moved significantly
    local cursor_moved = math.abs(mouse_pos.x - last_mouse_x) >= 2
    
    -- Update tracking state
    if cursor_moved then
        -- Cursor has moved, reset idle state
        cursor_last_moved_time = os.time()
        cursor_is_idle = false
        
        -- Calculate where the source should move to (but don't move it yet)
        cursor_target_position = calculate_source_position(mouse_pos)
        
        -- Update last mouse position
        last_mouse_x = mouse_pos.x
        last_mouse_y = mouse_pos.y
        
        debug_log("Cursor moved to: " .. mouse_pos.x .. " - target position: " .. 
                 (cursor_target_position and cursor_target_position or "none"))
    else
        -- Check if cursor has been idle long enough
        local current_time = os.time()
        local idle_time = current_time - cursor_last_moved_time
        
        if not cursor_is_idle and idle_time >= cursor_idle_delay then
            -- Cursor has been idle long enough, start the animation
            cursor_is_idle = true
            
            if cursor_target_position ~= nil then
                debug_log("Cursor idle for " .. idle_time .. " seconds, starting transition to target position")
                start_animation(cursor_target_position)
            end
        end
    end
end

-- Calculate the target position for the source based on mouse position
function calculate_source_position(mouse_pos)
    local source_position = nil
    
    -- Try to calculate the target position
    local success, error_message = pcall(function()
        -- Get current scene and source
        local current_scene_source = nil
        if scene_name ~= "" then
            current_scene_source = obs.obs_get_source_by_name(scene_name)
        else
            current_scene_source = obs.obs_frontend_get_current_scene()
        end
        
        if current_scene_source == nil then
            debug_log("Could not get scene for calculation")
            return nil
        end
        
        local current_scene = obs.obs_scene_from_source(current_scene_source)
        if current_scene == nil then
            obs.obs_source_release(current_scene_source)
            return nil
        end
        
        -- Get the source
        local source = obs.obs_get_source_by_name(source_name)
        if source == nil then
            debug_log("Could not find source for calculation")
            obs.obs_source_release(current_scene_source)
            return nil
        end
        
        -- Find the scene item
        local scene_item = obs.obs_scene_find_source(current_scene, source_name)
        if scene_item == nil then
            debug_log("Source not found in scene for calculation")
            obs.obs_source_release(source)
            obs.obs_source_release(current_scene_source)
            return nil
        end
        
        -- Get source info
        local pos = obs.vec2()
        obs.obs_sceneitem_get_pos(scene_item, pos)
        
        -- Get source bounds
        local bounds = obs.vec2()
        obs.obs_sceneitem_get_bounds(scene_item, bounds)
        
        -- Get canvas dimensions
        local canvas_width = 0
        local ovi = obs.obs_video_info()
        if obs.obs_get_video_info(ovi) then
            canvas_width = ovi.base_width
        else
            canvas_width = 1920  -- Fallback
        end
        
        -- Get the display dimensions to determine cursor range
        local display_width = 0
        if ffi.os == "OSX" then
            display_width = 1800
        else
            display_width = 1800
        end
        
        -- Calculate source width and allowed movement range
        local source_width = bounds.x
        local max_movement_range = source_width - canvas_width
        
        -- Ensure positive range
        if max_movement_range < 0 then
            max_movement_range = 0
        end
        
        -- Calculate the tracking area boundaries (centered in screen)
        local tracking_ratio = tracking_area_width / 100.0  -- Convert percentage to ratio
        local tracking_area_start = display_width * (0.5 - tracking_ratio/2)  -- Left boundary
        local tracking_area_end = display_width * (0.5 + tracking_ratio/2)    -- Right boundary
        local tracking_area_size = tracking_area_end - tracking_area_start
        
        debug_log("Tracking area: " .. tracking_area_start .. " to " .. tracking_area_end .. 
                 " (size: " .. tracking_area_size .. ")")
        
        -- Normalize mouse position to the tracking area (0.0 to 1.0)
        local mouse_normalized = 0.5  -- Default to center
        
        if mouse_pos.x <= tracking_area_start then
            -- Mouse is at or beyond left boundary of tracking area
            mouse_normalized = 0.0
        elseif mouse_pos.x >= tracking_area_end then
            -- Mouse is at or beyond right boundary of tracking area
            mouse_normalized = 1.0
        else
            -- Mouse is within tracking area - calculate normalized position
            mouse_normalized = (mouse_pos.x - tracking_area_start) / tracking_area_size
        end
        
        -- Apply sensitivity to make movement more responsive
        mouse_normalized = mouse_normalized * sensitivity
        
        -- Clamp value between 0 and 1
        mouse_normalized = math.max(0.0, math.min(1.0, mouse_normalized))
        
        -- Map the normalized position to source movement
        source_position = -1 * (mouse_normalized * max_movement_range)
        
        debug_log("Mouse at " .. mouse_pos.x .. " normalized to " .. mouse_normalized .. 
                 " in tracking area, position: " .. source_position)
        
        -- Release resources
        obs.obs_source_release(source)
        obs.obs_source_release(current_scene_source)
    end)
    
    if not success then
        debug_log("Error calculating position: " .. tostring(error_message))
        return nil
    end
    
    return source_position
end

-- Actually set the source position
function set_source_position(source_position)
    if source_position == nil then
        return
    end
    
    local success, error_message = pcall(function()
        -- Get current scene and source
        local current_scene_source = nil
        if scene_name ~= "" then
            current_scene_source = obs.obs_get_source_by_name(scene_name)
        else
            current_scene_source = obs.obs_frontend_get_current_scene()
        end
        
        if current_scene_source == nil then
            debug_log("Could not get scene for movement")
            return
        end
        
        local current_scene = obs.obs_scene_from_source(current_scene_source)
        if current_scene == nil then
            obs.obs_source_release(current_scene_source)
            return
        end
        
        -- Get the source
        local source = obs.obs_get_source_by_name(source_name)
        if source == nil then
            debug_log("Could not find source for movement")
            obs.obs_source_release(current_scene_source)
            return
        end
        
        -- Find the scene item
        local scene_item = obs.obs_scene_find_source(current_scene, source_name)
        if scene_item == nil then
            debug_log("Source not found in scene for movement")
            obs.obs_source_release(source)
            obs.obs_source_release(current_scene_source)
            return
        end
        
        -- Get current position to preserve Y
        local pos = obs.vec2()
        obs.obs_sceneitem_get_pos(scene_item, pos)
        
        -- Update only X position
        pos.x = source_position
        
        debug_log("Setting final position to: " .. pos.x .. ", " .. pos.y)
        
        -- Set the new position
        obs.obs_sceneitem_set_pos(scene_item, pos)
        
        -- Release resources
        obs.obs_source_release(source)
        obs.obs_source_release(current_scene_source)
    end)
    
    if not success then
        debug_log("Error setting position: " .. tostring(error_message))
    end
end

-- Function to periodically update the source position (with animation)
function script_tick(seconds)
    time_since_last_update = time_since_last_update + seconds
    
    -- Handle animation if in progress
    if animation_in_progress then
        animation_progress = animation_progress + seconds
        
        -- Calculate progress percentage (0.0 to 1.0)
        local progress_pct = math.min(1.0, animation_progress / animation_duration)
        
        -- Use easing function for smoother motion
        progress_pct = ease_out_quad(progress_pct)
        
        -- Calculate current position
        local current_pos = animation_start_pos + (animation_target_pos - animation_start_pos) * progress_pct
        
        -- Set the position
        set_source_position(current_pos)
        
        -- Check if animation is complete
        if progress_pct >= 1.0 then
            animation_in_progress = false
            debug_log("Animation complete")
        end
    end
    
    -- Run normal update at the specified interval
    if time_since_last_update >= update_interval then
        time_since_last_update = 0
        move_source()
    end
end

-- Easing function for smoother transitions
function ease_out_quad(t)
    return t * (2 - t)
end

-- Script description
function script_description()
    return "Moves a screen capture source based on cursor position for 9:16 format scenes. The source will move in the opposite direction of the cursor to keep the cursor visible in the center of the frame."
end

-- Function to toggle cursor tracking
function toggle_cursor_tracking(pressed)
    -- Only toggle on key press, not release
    if not pressed then
        return
    end
    
    -- Toggle the enabled state
    enabled = not enabled
    
    -- Log the state change
    debug_log("Hotkey pressed - Cursor tracking " .. (enabled and "enabled" or "disabled"))
end

-- Function called to save hotkey data
function script_save(settings)
    -- Save toggle hotkey data
    local hotkey_save_array = obs.obs_hotkey_save(hotkey_id)
    obs.obs_data_set_array(settings, "toggle_hotkey", hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)
    
    -- Save calibrate hotkey data
    local calibrate_hotkey_save_array = obs.obs_hotkey_save(calibrate_hotkey_id)
    obs.obs_data_set_array(settings, "calibrate_hotkey", calibrate_hotkey_save_array)
    obs.obs_data_array_release(calibrate_hotkey_save_array)
    
    debug_log("Script settings saved")
end

-- Function called on script load
function script_load(settings)
    -- Apply settings
    script_update(settings)
    
    -- Register hotkey
    hotkey_id = obs.obs_hotkey_register_frontend("cursor_tracker_toggle", "Toggle Cursor Tracking", toggle_cursor_tracking)
    
    -- Register calibration hotkey
    calibrate_hotkey_id = obs.obs_hotkey_register_frontend("cursor_tracker_calibrate", "Calibrate Cursor Tracking", calibrate_position)
    
    -- Load saved hotkey (if any)
    local hotkey_save_array = obs.obs_data_get_array(settings, "toggle_hotkey")
    obs.obs_hotkey_load(hotkey_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)
    
    local calibrate_hotkey_save_array = obs.obs_data_get_array(settings, "calibrate_hotkey")
    obs.obs_hotkey_load(calibrate_hotkey_id, calibrate_hotkey_save_array)
    obs.obs_data_array_release(calibrate_hotkey_save_array)
    
    debug_log("Script loaded. Platform: " .. ffi.os)
    debug_log("Enabled: " .. tostring(enabled))
    debug_log("Source: " .. source_name)
    debug_log("Hotkey registered")
    
    -- If needed, initialize any additional things here
end

-- Function called when script is unloaded
function script_unload()
    -- The toggle hotkey will be automatically released when the script unloads
    debug_log("Script unloaded")
end

-- Set default script settings
function script_defaults(settings)
    obs.obs_data_set_default_bool(settings, "enabled", false)
    obs.obs_data_set_default_double(settings, "sensitivity", 1.0)
    obs.obs_data_set_default_int(settings, "center_offset_x", 0)
    obs.obs_data_set_default_int(settings, "center_offset_y", 0)
    obs.obs_data_set_default_double(settings, "update_interval", 0.05)
    obs.obs_data_set_default_double(settings, "cursor_idle_delay", 0.5)
    obs.obs_data_set_default_double(settings, "animation_duration", 0.3)
    obs.obs_data_set_default_double(settings, "tracking_area_width", 80.0)
    debug_log("Default settings applied")
end

-- Function to calibrate/reset the base position
function calibrate_position(pressed)
    if not pressed then
        return
    end
    
    if source_name == "" then
        debug_log("Cannot calibrate: No source selected")
        return
    end
    
    local success, error_message = pcall(function()
        -- Get current scene
        local current_scene_source = nil
        if scene_name ~= "" then
            current_scene_source = obs.obs_get_source_by_name(scene_name)
        else
            current_scene_source = obs.obs_frontend_get_current_scene()
        end
        
        if current_scene_source == nil then
            debug_log("Could not get scene for calibration")
            return
        end
        
        local current_scene = obs.obs_scene_from_source(current_scene_source)
        if current_scene == nil then
            obs.obs_source_release(current_scene_source)
            return
        end
        
        -- Find the source
        local scene_item = obs.obs_scene_find_source(current_scene, source_name)
        if scene_item == nil then
            debug_log("Source not found in scene for calibration")
            obs.obs_source_release(current_scene_source)
            return
        end
        
        -- Get current position
        local pos = obs.vec2()
        obs.obs_sceneitem_get_pos(scene_item, pos)
        
        -- Get source bounds
        local bounds = obs.vec2()
        obs.obs_sceneitem_get_bounds(scene_item, bounds)
        
        -- Store the base position
        -- For most cases, the base position should be 0
        -- This allows the source to be aligned to the left edge of the canvas
        base_pos_x = 0
        
        -- Get mouse position
        local mouse_pos = get_mouse_position()
        initial_mouse_x = mouse_pos.x
        
        -- Get canvas dimensions
        local ovi = obs.obs_video_info()
        if obs.obs_get_video_info(ovi) then
            screen_center_x = ovi.base_width / 2 + center_offset_x
        else
            screen_center_x = 1920 / 2 + center_offset_x
        end
        
        debug_log("Calibration complete - Base position: " .. base_pos_x .. 
                 ", Source bounds: " .. bounds.x .. "x" .. bounds.y ..
                 ", Mouse: " .. initial_mouse_x .. 
                 ", Screen center: " .. screen_center_x)
        
        obs.obs_source_release(current_scene_source)
    end)
    
    if not success then
        debug_log("Calibration error: " .. tostring(error_message))
    end
end

-- Start a smooth animation to the target position
function start_animation(target_position)
    if animation_duration <= 0 then
        -- If animation duration is 0, just set the position immediately
        set_source_position(target_position)
        return
    end
    
    -- Get current position
    local current_pos = get_current_source_position()
    if current_pos == nil then
        -- If we can't get the current position, just set directly
        set_source_position(target_position)
        return
    end
    
    -- Set up animation
    animation_in_progress = true
    animation_start_pos = current_pos
    animation_target_pos = target_position
    animation_progress = 0
    
    debug_log("Starting animation from " .. animation_start_pos .. " to " .. animation_target_pos)
end

-- Get the current position of the source
function get_current_source_position()
    local position = nil
    
    local success, error_message = pcall(function()
        -- Get current scene and source
        local current_scene_source = nil
        if scene_name ~= "" then
            current_scene_source = obs.obs_get_source_by_name(scene_name)
        else
            current_scene_source = obs.obs_frontend_get_current_scene()
        end
        
        if current_scene_source == nil then
            return
        end
        
        local current_scene = obs.obs_scene_from_source(current_scene_source)
        if current_scene == nil then
            obs.obs_source_release(current_scene_source)
            return
        end
        
        -- Get the source and scene item
        local source = obs.obs_get_source_by_name(source_name)
        if source == nil then
            obs.obs_source_release(current_scene_source)
            return
        end
        
        local scene_item = obs.obs_scene_find_source(current_scene, source_name)
        if scene_item == nil then
            obs.obs_source_release(source)
            obs.obs_source_release(current_scene_source)
            return
        end
        
        -- Get current position
        local pos = obs.vec2()
        obs.obs_sceneitem_get_pos(scene_item, pos)
        position = pos.x
        
        -- Release resources
        obs.obs_source_release(source)
        obs.obs_source_release(current_scene_source)
    end)
    
    if not success then
        debug_log("Error getting current position: " .. tostring(error_message))
        return nil
    end
    
    return position
end
