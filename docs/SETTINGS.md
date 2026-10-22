# 设置组件约定

公共实现位于 App/Settings/SettingsComponents.swift。设置页提供文案、Binding、范围及操作回调；行布局和控件规格在公共组件中调整。

| 场景 | 使用组件 |
| --- | --- |
| 页头 | SettingPageHeader，可选 trailing 放置模块总开关 |
| 分组与说明 | SettingGroup、SettingSectionLabel；无内边距的 SettingSupportingText 与分组内的 SettingNote |
| 开关 | 普通设置用 SettingToggleRow；页头、模块列表与复合行用 SettingSwitch |
| 权限状态 | SettingPermissionRow，页面提供授权状态、状态文案和操作 |
| 枚举选择 | SettingPickerRow，只有互斥的短选项使用 segmented |
| 精确数值、日历提前提醒、倒计时 | SettingNumberRow，提供范围、步长与单位 |
| 体感类时长 | SettingSliderNumberRow，range 保留输入范围，可选 commonRange 指定滑块常用范围，不叠加步进器 |
| 其他滑块 | SettingSliderRow 用于滑块与只读数值；连续尺寸复用 SettingSliderNumberRow |
| 按钮操作 | SettingActionRow；复合行用 SettingRow，多项纵向操作用 SettingActions |
| 恢复与撤销 | SettingRestoreRow，由页面提供已有事务回调 |
| 折叠内容 | SettingDisclosureGroup，子行不再叠加水平内边距 |
| 搜索与多行信息 | SettingContent、SettingSearchField |

- 标题与说明共用左侧列；控件按右边缘对齐。选择器采用公共宽度，开关和按钮保留原生尺寸。不要在页面重新指定行内边距、字号、选择器宽度或缩小恢复按钮。
- 两层对齐是有意保留的标准：页头标题与模块总开关对齐卡片左右外缘，卡片内的文字与控件对齐内部内容边缘。页头用 SettingPageHeader 的 trailing 插槽，不在各页补偏移量，也不把总开关强行对齐卡片内的开关。
- SettingSwitch 统一原生常规尺寸、开关样式、隐藏视觉标签和保留可访问名称。调用方继续提供原有 Binding 及标识，模块开关与具体选项保持独立。
- SettingPermissionRow 统一已授权／Ready 的绿色勾选状态及未授权时的操作区域；单按钮和多按钮共用 SettingActions 的右对齐与间距。权限检查、拒绝／受限状态文案、请求权限与打开系统设置仍由页面决定；渲染组件不触发这些操作。通知权限原有的始终可打开设置入口继续使用 SettingActionRow。
- 设置辅助说明统一使用 SettingTypography.supporting（macOS 原生 callout，12 pt），包括行说明、SettingNote、恢复范围、兼容性、权限解释、诊断和搜索错误。继续使用系统次要颜色与自然换行；页面名称、设置标题、输入值和按钮保留原生字号。模块内的灵动岛字号不随设置页调整。
- 普通辅助说明使用 SettingSupportingText，统一字体、次要颜色和自动换行；需要卡片内边距时使用 SettingNote。动态日期等 SwiftUI Text 可直接传入。错误颜色和状态值等具有不同语义的内容继续显式保留其样式。
- 内置界面文案使用稳定的本地化键；英文显示文本也可以在 en.lproj 中优化，不修改偏好键或持久化枚举值。日历名称、账户来源名称和已格式化的数据源文本按原文显示：SettingRow／SettingSwitch 使用 localizesTitle: false，SettingNote 使用 localizesText: false，SettingSupportingText 使用 verbatim 初始化器。不要把用户内容当作翻译键；可访问名称也遵守同一规则。
- 根据语境命名选项：暂存架无期限保留使用 Keep forever／永久保留，置顶只表示不自动清理；NotchX 自身的 Energy saver／省电模式与 macOS Low Power Mode／低电量模式区分。保留时间、提醒展示时长与鼠标移开后的收起延迟不能混为一谈。中文统一使用“主页”“文稿”“自动提示”。
- 窄窗口中公共行把控件放到标题下方。同一个控件实例保留，避免窗口缩放丢失输入。
- 单位独立于输入框并本地化；默认值是恢复目标，不建立额外的“默认／自定义”模式。Binding 的持久化键、原始范围和业务副作用由原有状态所有者保留。
- 悬停延迟、展开收起延迟和所有事件展示时长使用连续滑块加可编辑数值；不设置离散滑块步长，避免把已有的精确值吸附到刻度。日历提前分钟数和倒计时保留数值加步进器。
- 常用范围：音量、电源状态、充满、设备连接／断开为 1～5 秒；低电量与通知为 1～10 秒；日历提醒展示为 1～15 秒；展开收起延迟为 0.1～3 秒；悬停延迟为 0～1 秒。事件输入仍允许 1～30 秒，收起延迟仍允许 0.1～10 秒，悬停仍允许 0～1.5 秒；尺寸与列宽不缩小范围。
- 旧值或新提交值超出常用范围时，滑块覆盖该值。本次页面显示期间只扩展、不随数值降低而缩小尺度，避免拖动时范围跳变；重新进入页面时用常用范围与当前值重新计算。不保存这类临时范围，不增加模式选项，不因浏览、格式化或缩放而写回偏好。
- 数值文本框由 SettingNumericTextField 使用原生 NSTextField 承载，在进入编辑前配置 cell 自有的 NSTextView，并只对这个数值编辑器关闭文本检查和自动补全。窗口共享文字编辑器、系统偏好和性能检查器均不改动；格式、范围和恢复保护继续由 SettingNumberField 管理。
- 输入草稿在回车或失焦时提交；非法输入回到当前有效值，越界值限制到原输入边界。未编辑的草稿不写回，显示格式不舍入存储值。滑块与输入框共用同一个值，分别应用滑块显示范围与原输入范围；未操作时不写回偏好。精确数值行的步进使用原生有界 Stepper。
- 整数状态可通过 Binding.settingInteger 接入数值行；输入提交时取最近整数，浏览不修改原值。
- 恢复／撤销在写入前更新 resetGeneration；模块恢复通过 settingResetGeneration 环境值传递。滑块操作、外部数值变更和恢复代次均使旧草稿失效，防止迟到的失焦事件覆盖新状态。
- 公共组件不申请权限、不创建管理器、不自行恢复偏好，也不触发设备操作。页面继续调用原有功能入口。

验证入口：scripts/test.sh、scripts/build-app.sh。SettingsLayoutTests 检查真实原生控件的对齐、折叠缩进、恢复尺寸、数值编辑与缩放保留输入；SettingsOrganizationTests 覆盖所有页面、中英文、两种窗口宽度及偏好兼容。真机视觉与交互验收见 [验收清单](ACCEPTANCE.md)。
