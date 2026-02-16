#include "VisionCamera.hpp"
#include <iostream>
#include <cmath>

#ifdef ANDROID
#include <android/log.h>
#define LOG_TAG "NativePlugin"
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)
#else
#define LOGD(...) printf(__VA_ARGS__)
#endif

/**
 * A sample C++ Plugin that processes every camera frame to compute average brightness.
 * This demonstrates the standardized high-performance C++ interface.
 */
class BrightnessPlugin : public vision::Plugin {
public:
    const char* name() const override {
        return "brightness_tracker";
    }

    void onFrame(const vision::Frame& frame) override {
        // Access raw Y-plane data (Zero-copy)
        const uint8_t* yData = frame.data();
        if (!yData) return;

        // Perform a super-fast brightness calculation on a 100x100 center crop
        int width = frame.width();
        int height = frame.height();
        int centerX = width / 2;
        int centerY = height / 2;
        
        long long sum = 0;
        int count = 0;
        
        // Sampling loop
        for (int y = centerY - 50; y < centerY + 50; ++y) {
            if (y < 0 || y >= height) continue;
            for (int x = centerX - 50; x < centerX + 50; ++x) {
                if (x < 0 || x >= width) continue;
                sum += yData[y * width + x];
                count++;
            }
        }

        if (count > 0) {
            double avg = (double)sum / count;
            // In a real plugin, you might call a callback into Dart or 
            // perform ML inference (TensorFlow Lite, OpenCV, etc).
            if (avg < 50.0) {
                LOGD("Brightness: Low (%.2f)", avg);
            } else if (avg > 200.0) {
                LOGD("Brightness: High (%.2f)", avg);
            }
        }
    }
};

// Auto-register the plugin when initialized (standard C/C++ pattern)
// In a real world, the user would call Registry::instance().addPlugin(...) from their code.
// we define a C-hook for the example to call.
extern "C" FFI_PLUGIN_EXPORT void VisionCamera_initExamplePlugin() {
    auto plugin = std::make_shared<BrightnessPlugin>();
    vision::Registry::instance().addPlugin(plugin);
}
