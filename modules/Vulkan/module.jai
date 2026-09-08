/*
VULKAN API BINDINGS

Vulkan 1.4.328.1

*/

#module_parameters();

// Helpers

VkVersion :: u32;

VK_Version :: struct {
    major, minor, patch: VkVersion;
}

vk_unmake_version :: (vk_version: VkVersion) -> VK_Version {
    major := VK_VERSION_MAJOR(vk_version);
    minor := VK_VERSION_MINOR(vk_version);
    patch := VK_VERSION_PATCH(vk_version);
    return .{major, minor, patch};
}

VK_NULL_HANDLE                    :: null;

VK_TRUE:                   VkBool32: 1;
VK_FALSE:                  VkBool32: 0;

VK_WHOLE_SIZE:             u64: xx ~0;
VK_ATTACHMENT_UNUSED:      u32: 0xffff_ffff;
VK_QUEUE_FAMILY_IGNORED:   u32: 0xffff_ffff;
VK_REMAINING_ARRAY_LAYERS: u32: 0xffff_ffff;
VK_REMAINING_MIP_LEVELS:   u32: 0xffff_ffff;
VK_SUBPASS_EXTERNAL:       u32: 0xffff_ffff;

VK_MAX_PHYSICAL_DEVICE_NAME_SIZE: u32: 256;
VK_UUID_SIZE:                     u32: 16;
VK_MAX_MEMORY_TYPES:              u32: 32;
VK_MAX_MEMORY_HEAPS:              u32: 16;
VK_MAX_EXTENSION_NAME_SIZE:       u32: 256;
VK_MAX_DESCRIPTION_SIZE:          u32: 256;

// Provided by VK_VERSION_1_0
// https://registry.khronos.org/vulkan/specs/1.3-extensions/man/html/VK_MAKE_VERSION.html
VK_MAKE_VERSION :: (major: u32, minor: u32, patch: u32) -> u32 #deprecated "VK_MAKE_API_VERSION should be used instead." {
    return (major << 22) | (minor << 12) | patch;
}

// Provided by VK_VERSION_1_0
// https://registry.khronos.org/vulkan/specs/1.3-extensions/man/html/VK_MAKE_API_VERSION.html
VK_MAKE_API_VERSION :: (variant:u32, major: u32, minor: u32, patch: u32) -> u32 {
    return (variant << 29) | (major << 22) | (minor << 12) | patch;
}

// Provided by VK_VERSION_1_0
VK_VERSION_MAJOR :: (version: u32) -> u32 #deprecated "VK_API_VERSION_MAJOR should be used instead." { return version >> 22; }

// Provided by VK_VERSION_1_0
VK_VERSION_MINOR :: (version: u32) -> u32 #deprecated "VK_API_VERSION_MINOR should be used instead." { return (version >> 12) & 0x3ff; }

// Provided by VK_VERSION_1_0
VK_VERSION_PATCH :: (version: u32) -> u32 #deprecated "VK_API_VERSION_PATCH should be used instead." { return version & 0xfff; }

VK_API_VERSION_1_0 :: #run VK_MAKE_API_VERSION(0, 1, 0, 0);
VK_API_VERSION_1_1 :: #run VK_MAKE_API_VERSION(0, 1, 1, 0);
VK_API_VERSION_1_2 :: #run VK_MAKE_API_VERSION(0, 1, 2, 0);
VK_API_VERSION_1_3 :: #run VK_MAKE_API_VERSION(0, 1, 3, 0);
VK_API_VERSION_1_4 :: #run VK_MAKE_API_VERSION(0, 1, 4, 0);
VK_HEADER_VERSION_COMPLETE :: #run VK_MAKE_API_VERSION(0, 1, 4, VK_HEADER_VERSION);


VK_API_VERSION_VARIANT :: (version: u32) -> u32 { return (version >> 29); }
VK_API_VERSION_MAJOR   :: (version: u32) -> u32 { return (version >> 22) & 0x3ff; }
VK_API_VERSION_MINOR   :: (version: u32) -> u32 { return (version >> 12) & 0x3ff; }
VK_API_VERSION_PATCH   :: (version: u32) -> u32 { return version & 0xfff; }

#if OS == .WINDOWS {
    #load "generated_windows.jai";
    #load "windows_extras.jai";

    libvulkan :: #library,no_dll "windows/vulkan-1";

    vkCreateWin32SurfaceKHR :: (instance: VkInstance, pCreateInfo: *VkWin32SurfaceCreateInfoKHR, pAllocator: *VkAllocationCallbacks, pSurface: *VkSurfaceKHR) -> VkResult #foreign libvulkan;
    vkGetPhysicalDeviceWin32PresentationSupportKHR :: (physicalDevice: VkPhysicalDevice, queueFamilyIndex: u32) -> VkBool32 #foreign libvulkan;
} else #if OS == .LINUX || OS == .ANDROID {
    #load "generated_linux.jai";
	#load "linux_extras.jai";
} else #if OS == .MACOS {
    #import "Metal";
    #load "generated_macos.jai";

    libvulkan :: #library "macos/libvulkan.1";
} else {
    #assert false  "Unsupported OS";
}

