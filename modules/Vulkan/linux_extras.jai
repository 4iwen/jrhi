VK_KHR_xlib_surface :: 1;
VK_KHR_XLIB_SURFACE_SPEC_VERSION :: 6;
VK_KHR_XLIB_SURFACE_EXTENSION_NAME :: "VK_KHR_xlib_surface";

VkXlibSurfaceCreateFlagsKHR :: VkFlags;
VkXlibSurfaceCreateInfoKHR :: struct {
    sType: VkStructureType = .XLIB_SURFACE_CREATE_INFO_KHR;
    pNext: *void;
    flags: VkXlibSurfaceCreateFlagsKHR;
    dpy: *Display;
    window: Window;
}

vkGetPhysicalDeviceXlibPresentationSupportKHR :: (
	physicalDevice: VkPhysicalDevice,
	queueFamilyIndex: u32,
	dpy: *Display,
	visualID: VisualID
) -> VkBool32 #foreign libvulkan;

vkCreateXlibSurfaceKHR :: (
	instance: VkInstance,
	pCreateInfo: *VkXlibSurfaceCreateInfoKHR,
	pAllocator: *VkAllocationCallbacks,
	pSurface: *VkSurfaceKHR
) -> VkResult #foreign libvulkan;

#scope_file
#import "X11";