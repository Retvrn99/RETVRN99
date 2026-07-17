// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:fmt"
import sdl3 "vendor:sdl3"

DEFAULT_WINDOW_SCALE :: 2
WIN_W :: TEXT_W * DEFAULT_WINDOW_SCALE // 1440
WIN_H :: TEXT_H * DEFAULT_WINDOW_SCALE + MENU_BAR_H
HOST_GPU_DRIVER :: "vulkan"
HOST_VULKAN_API_VERSION :: u32(0x0040_1000) // VK_MAKE_API_VERSION(0, 1, 1, 0)

Host :: struct {
	win:                 ^sdl3.Window,
	ren:                 ^sdl3.Renderer,
	gpu:                 ^sdl3.GPUDevice,
	tex:                 ^sdl3.Texture,
	gpu_surfaces:        [HOST_GPU_SURFACE_CAPACITY]Host_Gpu_Surface,
	gpu_surface_bytes:   u64,
	gpu_present:         Host_Gpu_Present,
	gpu_direct_presents: u64,
	gsw3d_bridge:        Gsw3d_Bridge,
	gsw3d_triangle:      Gsw3d_Triangle_Renderer,
	gsw3d_backend:       Gsw3d_Proof_Backend,
	gsw3d_executor:      Gsw3d_Proof_Executor,
	gsw3d_proof_enabled: bool,
	shader:              ^sdl3.GPUShader,
	shader_state:        ^sdl3.GPURenderState,
	tex_width:           int,
	tex_height:          int,
	aspect_width:        int,
	aspect_height:       int,
	window_scale:        int,
	fullscreen:          bool,
	menu_reveal:         f32,
	visual_shader:       Visual_Shader,
	storage_icons:       Storage_Icon_Textures,
	has_frame:           bool,
	vsync:               bool, // presents are paced by the display; else the UI loop sleeps
	mouse_captured:      bool,
	mouse_buttons:       u8,
}

@(private = "file")
host_create_gpu_device :: proc() -> ^sdl3.GPUDevice {
	props := sdl3.CreateProperties()
	if props == 0 {return nil}
	defer sdl3.DestroyProperties(props)
	vulkan := sdl3.GPUVulkanOptions {
		vulkan_api_version = HOST_VULKAN_API_VERSION,
	}
	if !sdl3.SetStringProperty(props, sdl3.PROP_GPU_DEVICE_CREATE_NAME_STRING, HOST_GPU_DRIVER) ||
	   !sdl3.SetBooleanProperty(props, sdl3.PROP_GPU_DEVICE_CREATE_SHADERS_SPIRV_BOOLEAN, true) ||
	   !sdl3.SetPointerProperty(
			   props,
			   sdl3.PROP_GPU_DEVICE_CREATE_VULKAN_OPTIONS_POINTER,
			   &vulkan,
		   ) {
		return nil
	}
	return sdl3.CreateGPUDeviceWithProperties(props)
}

host_init :: proc(h: ^Host) -> (ok: bool) {
	h^ = {}
	defer if !ok {host_destroy(h)}
	if !sdl3.Init({.VIDEO}) {
		return false
	}
	gsw3d_bridge_init(&h.gsw3d_bridge)
	// no RESIZABLE flag: fixed-size window
	h.win = sdl3.CreateWindow("RETVRN99", WIN_W, WIN_H, {})
	if h.win == nil {
		return false
	}
	h.gpu = host_create_gpu_device()
	if h.gpu == nil {return false}
	driver := sdl3.GetGPUDeviceDriver(h.gpu)
	if driver == nil || string(driver) != HOST_GPU_DRIVER {
		_ = sdl3.SetError("SDL did not select the required Vulkan GPU driver")
		return false
	}
	h.ren = sdl3.CreateGPURenderer(h.gpu, h.win)
	if h.ren == nil {return false}
	if !storage_icon_textures_init(&h.storage_icons, h.ren) {
		_ = sdl3.SetError("built-in storage icons could not be loaded")
		return false
	}
	fmt.printfln("video: SDL GPU renderer (%s)", driver)
	h.vsync = sdl3.SetRenderVSync(h.ren, 1) // never busy-spin the UI loop
	h.tex = sdl3.CreateTexture(h.ren, .ARGB8888, .STREAMING, TEXT_W, TEXT_H)
	if h.tex == nil {
		return false
	}
	h.window_scale = DEFAULT_WINDOW_SCALE
	h.menu_reveal = 1
	h.tex_width = TEXT_W
	h.tex_height = TEXT_H
	h.aspect_width = 4
	h.aspect_height = 3
	if host_shader_init(h) {
		_ = host_set_visual_shader(h, .Subtle)
	} else {
		_ = host_set_visual_shader(h, .None)
	}
	return true
}

host_destroy :: proc(h: ^Host) {
	if h.mouse_captured {_ = sdl3.SetWindowRelativeMouseMode(h.win, false)}
	gsw3d_bridge_shutdown(&h.gsw3d_bridge)
	if h.gsw3d_proof_enabled {_ = host_gsw3d_proof_reset(h, 0)}
	gsw3d_triangle_renderer_destroy(&h.gsw3d_triangle)
	host_shader_destroy(h)
	if h.tex != nil {sdl3.DestroyTexture(h.tex)}
	host_gpu_surfaces_destroy(h)
	storage_icon_textures_destroy(&h.storage_icons)
	if h.ren != nil {sdl3.DestroyRenderer(h.ren)}
	if h.gpu != nil {sdl3.DestroyGPUDevice(h.gpu)}
	if h.win != nil {sdl3.DestroyWindow(h.win)}
	sdl3.Quit()
}

host_set_window_scale :: proc(h: ^Host, scale: int) -> bool {
	if h == nil || h.win == nil || h.fullscreen || scale < 2 || scale > 4 {return false}
	if !sdl3.SetWindowSize(h.win, i32(TEXT_W * scale), i32(TEXT_H * scale + MENU_BAR_H)) {
		return false
	}
	_ = sdl3.SetWindowPosition(h.win, sdl3.WINDOWPOS_CENTERED, sdl3.WINDOWPOS_CENTERED)
	h.window_scale = scale
	return true
}

fullscreen_window_rect :: proc(display_bounds: sdl3.Rect) -> sdl3.Rect {
	result := display_bounds
	result.h += 1
	return result
}

host_set_fullscreen :: proc(h: ^Host, enabled: bool) -> bool {
	if h == nil || h.win == nil || h.fullscreen == enabled {return h != nil}
	if enabled {
		display := sdl3.GetDisplayForWindow(h.win)
		bounds: sdl3.Rect
		if display == 0 || !sdl3.GetDisplayBounds(display, &bounds) {return false}
		bounds = fullscreen_window_rect(bounds)
		// Deliberately avoid SDL's fullscreen path. A borderless window that is one
		// pixel taller than the display sidesteps Windows 11 fullscreen optimization.
		if !sdl3.SetWindowBordered(h.win, false) {return false}
		if !sdl3.SetWindowPosition(h.win, bounds.x, bounds.y) ||
		   !sdl3.SetWindowSize(h.win, bounds.w, bounds.h) {
			_ = sdl3.SetWindowBordered(h.win, true)
			return false
		}
		_ = sdl3.SyncWindow(h.win)
	} else {
		if !sdl3.SetWindowBordered(h.win, true) {return false}
		_ = sdl3.SetWindowSize(
			h.win,
			i32(TEXT_W * h.window_scale),
			i32(TEXT_H * h.window_scale + MENU_BAR_H),
		)
		_ = sdl3.SetWindowPosition(h.win, sdl3.WINDOWPOS_CENTERED, sdl3.WINDOWPOS_CENTERED)
		_ = sdl3.SyncWindow(h.win)
	}
	h.fullscreen = enabled
	return true
}

host_toggle_fullscreen :: proc(h: ^Host) -> bool {
	return h != nil && host_set_fullscreen(h, !h.fullscreen)
}
