# SwiftUI 排序（macOS 26+）

`App/Views/Shared/ReorderableContainer.swift` 直接适配 Maccy 的新系统实现，固定上游修订 `c700182f638d9d29bfa0aec9dc560422698854c6`。原始路径为 `Maccy/Views/ReorderableContainer.swift`；保留 MIT 版权与完整许可证（`Licenses/Maccy-MIT.txt`，随应用打包）。来源与差异另见 `THIRD_PARTY_NOTICES.md`。没有引入依赖或复制 Telegram 代码。

## 适配边界

- 保留上游 `.onDrag`、`.onDragSessionUpdated`、`.onDropSessionUpdated`、本进程 item provider、上下半区与移动索引算法。整个应用最低 macOS 26，不保留 `LegacyReorderableContainer` 或 AppKit 旧系统桥接。
- 移除 Maccy 自有的多选／导航全局状态耦合，当前仅拖动一个项目。容器与条目不认识模块、列表、偏好持久化；其他纵向排序视图可复用，但不是文件拖出或二维网格的通用拖放引擎。
- `ModuleManagementList` 使用稳定模块身份渲染原生 SwiftUI 行；整行可拖动，预览包含名称、开关和详情。换位沿用 `PinsView.swift` 的 `.default.speed(2)`，减少动态效果时不增加换位动画。没有 NSTableView、gap、独立浮层、位图／坐标追踪或自定义松手收尾。
- 与 Maccy 一致，悬停越过目标即换位并持久化；成功或取消仅清除拖动态，不回滚已经完成的换位。项目退出／结束不需要等待手写动画回调。
- 上移／下移仅在右键菜单和无障碍动作中提供，首尾不可越界，没有可见排序按钮、排序快捷键或选中态。开关与详情保持独立操作，浏览不申请系统权限。
- 模块页的内部恢复会话以 AppState 实例身份为边界；外层视图身份不变时切换实例，会重建内部会话，丢弃旧实例的撤销记录和待确认恢复。详情页同时以模块身份隔离会话。

## 验证边界

`ReorderableContainerTests` 验证实际上游算法及真实 SwiftUI 容器暴露的处理器：连续移动、反向、重复／自身／异类型目标、结束清理以及取消不回滚。它不伪造 macOS 拖动事件，也不能证明真实鼠标拖动的动画或系统回调闭环。

`ModuleReorderingTests` 在中英文、窄宽窗口下检查实际无障碍动作、开关、详情与非默认顺序持久化；直接测试 `AppState.moveModules` 命令在默认／逆序数据上的跨行、首尾与反向移动、实际行位置和重建读回结果，以及无效／无变化输入不写偏好。接线测试挂载生产列表使用的 `ModuleManagementDragModifier`，调用其中真实上游环境上下文的开始、悬停与结束处理器，经 `moveAction` 和原动画包装进入 AppState 命令，检查正反向移动、重复目标及取消清理，不直接调用排序命令或替换移动算法。

实例切换测试通过同一个宿主、同一外层视图身份动态替换 AppState，检查排序恢复／撤销不跨偏好域，旧确认框被丢弃，新确认只恢复新实例；另保留不同外层环境对象的隔离测试。这些测试不构造系统拖放会话，也不证明鼠标回调或预览动画表现。真实拖动、边缘滚动、松手／Esc／移出后的屏幕表现与 VoiceOver 手感由用户验收，本轮不运行真实交互探针。
