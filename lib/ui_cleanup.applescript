-- =============================================================
-- ui_cleanup.applescript —— 后台清理浏览器注销页 / 重复 VPN 标签
-- =============================================================
-- 只做两件事，全部通过辅助功能（AX）在后台完成：
--   1) 关闭 Chrome 里所有「用户注销成功」标签（标题含
--      注销成功 / por/logout / logout.csp），一个不留；
--   2) 「内网VPN远程系统」标签重复时，只保留第一个，其余关掉；
--   3) 顺手点掉 EasyConnect「最近登录信息 / Login History」窗口的「确定」。
--
-- 安全边界（2026-10-22 重写，修复误关终端的问题）：
--   * 绝不发送任何键盘事件（不使用 keystroke），不会影响其他应用；
--   * 只对拥有可见窗口的 Google Chrome 实例操作，
--     Playwright 等无窗口实例一律跳过；
--   * 选中标签后必须确认窗口标题已切换，再按该标签自己的 Close 按钮；
--   * 只匹配明确标题，绝不按索引盲关。
-- =============================================================

on run argv
    set closedLogout to 0
    set closedDup to 0
    set dismissed to 0
    set detail to ""

    tell application "System Events"
        -- 只处理有窗口的 Chrome（排除 Playwright 等后台实例）
        repeat with p in (every process whose name is "Google Chrome")
            set winCount to 0
            try
                set winCount to count of windows of p
            end try
            if winCount > 0 then
                set r to my cleanChrome(p)
                set closedLogout to closedLogout + (item 1 of r)
                set closedDup to closedDup + (item 2 of r)
                set detail to detail & (item 3 of r)
            end if
        end repeat

        -- EasyConnect「最近登录信息」窗口
        set dismissed to my dismissLoginInfo()
    end tell

    return "closed_logout=" & closedLogout & " closed_dup=" & closedDup & " dismissed=" & dismissed & detail
end run


-- ============ Chrome：注销页 + 重复 VPN 标签 ============
on cleanChrome(p)
    set closedLogout to 0
    set closedDup to 0
    set detail to ""
    tell application "System Events"
        set winCount to 0
        try
            set winCount to count of windows of p
        end try
        repeat with wi from winCount to 1 by -1
            -- 1) 注销页：从后往前，关到一个不剩
            repeat
                set tabs to {}
                try
                    set tabs to my findTabs(window wi of p, 1)
                end try
                set target to 0
                repeat with i from 1 to (count of tabs)
                    set nm to ""
                    try
                        set nm to name of item i of tabs
                    end try
                    if my isLogoutTitle(my baseTitle(nm)) then set target to i
                end repeat
                if target is 0 then exit repeat
                if my closeTabAt(p, wi, target) then
                    set closedLogout to closedLogout + 1
                    set detail to detail & " [注销页]"
                    delay 0.35
                else
                    exit repeat
                end if
                if closedLogout > 100 then exit repeat
            end repeat

            -- 2) 重复的内网 VPN 远程系统标签：保留第一个
            delay 0.2
            set tabs to {}
            try
                set tabs to my findTabs(window wi of p, 1)
            end try
            set seen to {}
            set dupIdx to {}
            repeat with i from 1 to (count of tabs)
                set nm to ""
                try
                    set nm to name of item i of tabs
                end try
                set base to my baseTitle(nm)
                if base contains "内网VPN远程系统" then
                    if seen contains base then
                        set end of dupIdx to i
                    else
                        set end of seen to base
                    end if
                end if
            end repeat
            repeat with k from (count of dupIdx) to 1 by -1
                set target to item k of dupIdx
                if my closeTabAt(p, wi, target) then
                    set closedDup to closedDup + 1
                    set detail to detail & " [重复VPN]"
                    delay 0.35
                end if
            end repeat
        end repeat
    end tell
    return {closedLogout, closedDup, detail}
end cleanChrome


-- 选中第 idx 个标签，确认标题已切换，再按该标签自身的 Close 按钮
on closeTabAt(p, wi, idx)
    tell application "System Events"
        try
            set tabs to my findTabs(window wi of p, 1)
            if idx > (count of tabs) then return false
            set t to item idx of tabs
            set expectBase to my baseTitle(name of t)

            try
                perform action "AXPress" of t
                delay 0.35
            end try

            -- 校验窗口标题已切到目标标签，否则绝不点关闭
            set wt to ""
            try
                set wt to name of window wi of p
            end try
            if wt does not contain expectBase then return false

            set tabs2 to my findTabs(window wi of p, 1)
            if idx > (count of tabs2) then return false
            set btn to my findCloseButton(item idx of tabs2, 1)
            if btn is missing value then return false
            perform action "AXPress" of btn
            return true
        on error
            return false
        end try
    end tell
end closeTabAt


-- ============ EasyConnect：最近登录信息 ============
on dismissLoginInfo()
    set n to 0
    tell application "System Events"
        repeat with p in (every process whose name is "EasyConnect")
            set winCount to 0
            try
                set winCount to count of windows of p
            end try
            repeat with wi from 1 to winCount
                try
                    set w to window wi of p
                    set wn to name of w
                    if wn contains "登录信息" or wn contains "Login History" then
                        set btn to my findConfirmButton(w, 1)
                        if btn is missing value then
                            set btn to my lowestButton(w, 1)
                        end if
                        if btn is not missing value then
                            perform action "AXPress" of btn
                            set n to n + 1
                            delay 0.2
                        end if
                    end if
                end try
            end repeat
        end repeat
    end tell
    return n
end dismissLoginInfo


-- ============ 工具 ============
on findTabs(el, depth)
    set res to {}
    if depth > 12 then return res
    tell application "System Events"
        try
            if (role of el) is "AXRadioButton" then return {el}
        on error
            return res
        end try
        try
            set ch to every UI element of el
        on error
            return res
        end try
        repeat with c in ch
            set res to res & (my findTabs(c, depth + 1))
        end repeat
    end tell
    return res
end findTabs

on findCloseButton(el, depth)
    set res to missing value
    if depth > 6 then return res
    tell application "System Events"
        try
            if (role of el) is "AXButton" then
                set nm to ""
                try
                    set nm to name of el
                end try
                if nm is "Close" or nm contains "关闭" then return el
            end if
        on error
            return res
        end try
        try
            set ch to every UI element of el
        on error
            return res
        end try
        repeat with c in ch
            set r to my findCloseButton(c, depth + 1)
            if r is not missing value then return r
        end repeat
    end tell
    return res
end findCloseButton

on findConfirmButton(el, depth)
    set res to missing value
    if depth > 12 then return res
    tell application "System Events"
        try
            if (role of el) is "AXButton" then
                set nm to ""
                try
                    set nm to name of el
                end try
                if nm is "确定" or nm is "OK" or nm is "好" then return el
            end if
        on error
            return res
        end try
        try
            set ch to every UI element of el
        on error
            return res
        end try
        repeat with c in ch
            set r to my findConfirmButton(c, depth + 1)
            if r is not missing value then return r
        end repeat
    end tell
    return res
end findConfirmButton

on lowestButton(el, depth)
    set res to missing value
    set maxY to -100000
    tell application "System Events"
        set btns to my collectButtons(el, 1)
        repeat with b in btns
            try
                set {bx, py} to position of b
                if py > maxY then
                    set maxY to py
                    set res to b
                end if
            end try
        end repeat
    end tell
    return res
end lowestButton

on collectButtons(el, depth)
    set res to {}
    if depth > 12 then return res
    tell application "System Events"
        try
            if (role of el) is "AXButton" then return {el}
        on error
            return res
        end try
        try
            set ch to every UI element of el
        on error
            return res
        end try
        repeat with c in ch
            set res to res & (my collectButtons(c, depth + 1))
        end repeat
    end tell
    return res
end collectButtons

on baseTitle(nm)
    set base to nm
    if nm contains " - Memory usage" then
        try
            set base to text 1 thru ((offset of " - Memory usage" in nm) - 1) of nm
        end try
    end if
    return base
end baseTitle

on isLogoutTitle(base)
    if base contains "注销成功" then return true
    if base contains "por/logout" then return true
    if base contains "logout.csp" then return true
    return false
end isLogoutTitle
