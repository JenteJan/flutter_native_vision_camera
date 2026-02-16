#pragma once

#include "flutter_native_vision_camera.h"
#include <functional>
#include <vector>
#include <string>
#include <memory>
#include <mutex>

namespace vision {

/**
 * C++ Wrapper for Vision Camera Frame.
 */
class Frame {
public:
    Frame(FrameHandle handle, FrameMetadata metadata) 
        : handle_(handle), metadata_(metadata) {}

    int width() const { return metadata_.width; }
    int height() const { return metadata_.height; }
    double timestamp() const { return metadata_.timestamp; }
    int orientation() const { return metadata_.orientation; }
    int pixelFormat() const { return metadata_.pixelFormat; }

    /**
     * Get raw pointer to the Y-plane (or first plane).
     */
    const uint8_t* data() const {
        return static_cast<const uint8_t*>(Frame_getPlanePointer(handle_, 0));
    }

    /**
     * Get pointer to a specific plane (e.g. 1 for U, 2 for V in YUV).
     */
    const uint8_t* plane(int index) const {
        return static_cast<const uint8_t*>(Frame_getPlanePointer(handle_, index));
    }

    /**
     * Get bytes per row for the first plane.
     */
    int bytesPerRow() const {
        return Frame_getBytesPerRow(handle_);
    }

    /**
     * Get total size of the first plane.
     */
    size_t size() const {
        return static_cast<size_t>(Frame_getPlaneSize(handle_, metadata_, 0));
    }

private:
    FrameHandle handle_;
    FrameMetadata metadata_;
};

/**
 * Base class for C++ Vision Camera Plugins.
 * Developers should inherit from this class to implement custom vision logic.
 */
class Plugin {
public:
    virtual ~Plugin() = default;
    
    /**
     * Unique identifier for the plugin.
     */
    virtual const char* name() const = 0;

    /**
     * Called for every camera frame.
     * Note: This is called on a high-priority background thread.
     */
    virtual void onFrame(const Frame& frame) = 0;

    /**
     * Signal to cleanup resources.
     */
    virtual void onDestroy() {}
};

/**
 * Global Registry for C++ Plugins.
 */
class Registry {
public:
    static Registry& instance() {
        static Registry i;
        return i;
    }

    /**
     * Register a C++ plugin instance.
     */
    void addPlugin(std::shared_ptr<Plugin> plugin) {
        std::lock_guard<std::mutex> lock(mutex_);
        plugins_.push_back(plugin);
        
        // Register the C-compatible hook
        VisionCameraPlugin nativePlugin;
        nativePlugin.name = plugin->name();
        nativePlugin.onFrame = [](FrameHandle handle, FrameMetadata metadata) {
            auto& reg = Registry::instance();
            std::lock_guard<std::mutex> innerLock(reg.mutex_);
            for (auto& p : reg.plugins_) {
                p->onFrame(Frame(handle, metadata));
            }
        };
        nativePlugin.onDestroy = []() {
            // Cleanup triggered by C layer
        };
        
        VisionCamera_registerPlugin(nativePlugin);
    }

private:
    std::mutex mutex_;
    std::vector<std::shared_ptr<Plugin>> plugins_;
};

} // namespace vision
