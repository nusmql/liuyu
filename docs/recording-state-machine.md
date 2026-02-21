# Recording State Machine

## 状态定义

```
┌─────────┐    keyDown     ┌─────────────┐   0.5s timer   ┌───────────┐
│  idle   │ ─────────────→ │ debouncing  │ ─────────────→ │ recording │
└─────────┘                └─────────────┘                └───────────┘
     ↑                            │    keyUp (cancel)           │
     │                            └─────────────────────────────┘
     │                                                          │
     │                    ┌─────────────┐   silence timeout    │
     │                    │ processing  │ ←─────────────────────┘
     │                    └─────────────┘        or keyUp
     │                          │
     │         success          │
     │    ┌─────────────────────┘
     │    │
     │    ▼
     │ ┌─────────┐
     └─┤completed│
       └─────────┘
```

## 状态说明

| 状态 | 说明 | 转移条件 |
|------|------|----------|
| `idle` | 空闲状态，等待输入 | keyDown → debouncing |
| `debouncing` | 防抖动状态（0.5s） | 0.5s后 → recording<br>keyUp → idle (cancel) |
| `recording` | 录音中 | silence timeout → processing<br>keyUp → processing |
| `processing` | 转录中 | 完成后 → completed |
| `completed` | 完成，显示结果 | 自动 → idle |
| `error` | 错误状态 | 可返回 idle |

## 使用 Combine 的优势

1. **单一状态源**: `RecordingState.shared` 管理所有状态
2. **响应式更新**: UI 自动响应状态变化
3. **自动清理**: 状态转移时自动清理资源
4. **可测试**: 状态机逻辑可独立测试

## 代码示例

```swift
// 在 AppDelegate 中订阅状态变化
RecordingState.shared.$phase
    .sink { phase in
        switch phase {
        case .recording:
            self.showRecordingUI()
        case .processing:
            self.showProcessingUI()
        case .completed(let text):
            self.showEditWindow(text: text)
        default:
            break
        }
    }
```
