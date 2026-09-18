# Jai-Vulkan

These bindings are based on [St0wy/jai-vulkan](https://codeberg.org/St0wy/jai-vulkan) commit
[`683e0346a0151c6e0c721e7d8a9dd6158fd7d5c6`](https://codeberg.org/St0wy/jai-vulkan/commit/683e0346a0151c6e0c721e7d8a9dd6158fd7d5c6).

Generated registry versions:

- macOS and Windows: Vulkan 1.4.357.0
- Linux: Vulkan 1.4.328.0

`macos/libvulkan.1.dylib` is the universal Apple Silicon and Intel loader from LunarG Vulkan SDK 1.4.357.1.

## Contributing

To regenerate the bindings, first make sure the [Vulkan SDK](https://vulkan.lunarg.com/sdk/home) is installed on your system.
Then run :

```
jai generate.jai
```
