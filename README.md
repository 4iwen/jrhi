# JRHI

A Vulkan RHI written in Jai.

## Features

- Vulkan 1.3 instance and device creation
- One automatically selected graphics GPU and queue
- Optional Khronos validation layer
- One JRHI context stored in Jai's implicit `Context`
- GPU-only, CPU-write, and CPU-read memory with 64-bit GPU addresses
- Command lists for GPU fills and buffer copies
- Explicit immediate and deferred memory freeing

## Platform Support

- macOS - tested on Apple Silicon with LunarG Vulkan SDK and MoltenVK
- Windows and Linux - bindings are included but runtime support is not tested yet

## Cloning

```bash
git clone https://github.com/4iwen/jrhi.git
```

## Development Setup

Install Jai and the [LunarG Vulkan SDK](https://vulkan.lunarg.com/sdk/home).

Before building, source the SDK environment script:

```bash
source <VulkanSDK-install>/setup-env.sh
vulkaninfo --summary
```

## Examples

```bash
jai examples/triangle.jai
./examples/triangle
```

## Current Limitations

- Only one graphics queue and one recording command list are available.
- `submit` waits for the GPU before returning.
- If `submit` fails, destroy and recreate JRHI before using it again.

## Testing

```bash
jai tests/run.jai
./tests/test
```

## Dependencies

- [jai-vulkan](https://codeberg.org/St0wy/jai-vulkan) - Vulkan bindings
- [Stubborn](https://github.com/rluba/stubborn) - Test assertions and matchers
