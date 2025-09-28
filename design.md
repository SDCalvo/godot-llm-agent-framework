# LLM Add-on TODO List

## 🎯 Current Status

- ✅ **Buttons Working!** - Fixed CanvasLayer input bug by moving to standard Control hierarchy
- ✅ **Console Scrolling** - Works properly
- ✅ **WASD Camera Movement** - Working correctly
- ✅ **LLM Agent Streaming** - Parallel tool calls and race conditions resolved
- ✅ **Thread Safety** - Tool registry handles node access properly

## 🔧 Immediate Fixes Needed

### 1. **Middle-Click Camera Drag** 🖱️

- **Issue**: Middle mouse button drag not working for camera movement
- **Current**: WASD works fine, but middle-click drag doesn't respond
- **Debug**: Camera script uses `_unhandled_input()` with `MOUSE_BUTTON_MIDDLE` detection
- **Possible Causes**:
  - Input event not reaching camera script
  - UI elements consuming middle-click events
  - Event handling order issues
- **Next Steps**:
  - Add more debug prints to see if middle-click events are detected
  - Try `_input()` instead of `_unhandled_input()`
  - Check if any UI elements are blocking input

### 2. **Console Scroll vs World Zoom Conflict** 🎯

- **Issue**: Mouse wheel scrolls console BUT also zooms world camera simultaneously
- **Expected**: Mouse wheel should only zoom world when NOT over console
- **Current**: Both actions happen at once
- **Solution Needed**:
  - Detect when mouse is over console area
  - Prevent camera zoom when scrolling console
  - Use input event consumption properly

### 3. **Button Panel Sizing** 📏

- **Issue**: Button panel is too large
- **Current**: Panel offset values are very large (`-926.0`, `396.0`)
- **Needed**: Resize to more reasonable dimensions
- **Target**: Compact panel that fits buttons nicely

## 🎨 UI/UX Improvements

### 4. **Camera Controls Polish**

- **Add visual feedback** for camera controls (crosshair, grid snapping)
- **Improve zoom limits** and smooth zoom behavior
- **Add camera reset** button to return to (0,0)

### 5. **Console Enhancements**

- **Auto-scroll to bottom** when new content added
- **Syntax highlighting** for LLM responses
- **Timestamp** for each test output
- **Export/save** console output to file

### 6. **Button Layout Optimization**

- **Group related buttons** (Wrapper tests, Agent tests, Tool tests)
- **Add tooltips** explaining what each test does
- **Visual feedback** when tests are running (loading indicators)

## 🔧 Technical Debt

### 7. **Code Organization**

- **Split control.gd** into smaller, focused scripts
- **Extract test functions** into separate test manager class
- **Improve error handling** and user feedback

### 8. **Performance Optimization**

- **Optimize camera following** script (currently runs every frame)
- **Lazy load** LLM components only when needed
- **Memory management** for large console outputs

## 🚀 Future Features

### 9. **Advanced Testing**

- **Automated test suite** for all LLM functionality
- **Performance benchmarks** for different model sizes
- **Stress testing** with multiple parallel agents

### 10. **Developer Experience**

- **Better documentation** with code examples
- **Video tutorials** for common use cases
- **Template scenes** for quick setup

## 📋 Session Notes

### Last Session Progress:

1. **Fixed major CanvasLayer bug** - Buttons now clickable by moving to standard Control hierarchy
2. **Resolved script inheritance error** - Moved control.gd to proper CanvasLayer
3. **Implemented proper signal connections** - All button handlers working
4. **Eliminated input region misalignment** - No more visual/input offset issues

### Key Learnings:

- **CanvasLayer offset manipulation** causes known Godot input bugs
- **Standard Control anchoring** is more reliable for UI elements
- **Thread safety** critical for LLM tool execution
- **Streaming API race conditions** require careful batch handling

---

## 🎯 Next Session Priority:

1. **Fix middle-click camera drag** (highest priority)
2. **Resolve console scroll/zoom conflict**
3. **Resize button panel** for better UX

**Estimated Time**: 1-2 hours for core fixes, additional time for polish features.
