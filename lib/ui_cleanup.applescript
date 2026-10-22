-- =============================================================
-- ui_cleanup.applescript —— EasyConnect 守护的界面清理器
-- =============================================================
-- 背景：EC 每次重启/重新登录后，浏览器里旧的资源页会跳转成
--       “用户注销成功”并留在标签页；同时 EC 右上角会弹出
--       “最近登录信息”窗口。两者不断累积影响使用。
-- 做法：
--   1) 找出 Chrome 里标题含“注销成功 / por/logout”的标签页，
--      逐个选中（确认窗口标题已切换）后按 Cmd+W 关闭；
--   2) 找到 EasyConnect 的“最近登录信息 / Login History”窗口，
--      点它的“确定/OK”按钮（找不到按钮时点最下方按钮兜底）。
-- 参数：轮数（默认 8）。每轮间隔 8 秒，覆盖登录前后页面跳转。
--
-- 安全边界：
--   * 只关闭标题明确匹配注销页的标签，绝不关闭其他网页；
--   * 选中后必须确认窗口标题已切换到该标签，否则跳过不按 Cmd+W；
--   * 清理结束把焦点还给原来的前台应用。
-- =============================================================

on run argv
    set maxRounds to 8
    if (count of argv) > 0 then
        try
            set maxRounds to (item 1 of argv) as integer
        end try
    end if

    set totalClosed to 0
    set totalDismissed to 0
    set idleRounds to 0

    repeat with roundNo from 1 to maxRounds
        set closedCount to my closeLogoutTabs()
        set dismissedCount to my dismissLoginInfo()
        set totalClosed to totalClosed + closedCount
        set totalDismissed to totalDismissed + dismissedCount

        if closedCount is 0 and dismissedCount is 0 then
            set idleRounds to idleRounds + 1
        else
            set idleRounds to 0
        end if

        -- 至少跑 3 轮以覆盖登录完成后的弹窗；连续 2 轮无事可做提前结束
        if roundNo ≥ 3 and idleRounds ≥ 2 then exit repeat
        if roundNo < maxRounds then delay 8
    end repeat

    return "closed=" & totalClosed & " dismissed=" & totalDismissed
end run


-- ---------- 关闭 Chrome 中的注销标签页 ----------
on closeLogoutTabs()
    set closedCount to 0
    tell application "System Events"
        -- 记录当前前台应用，结束后恢复焦点
        set prevName to ""
        try
            set prevName to name of first process whose frontmost is true
        end try

        repeat with p in (every process whose name is "Google Chrome")
            try
                set winCount to count of windows of p
            on error
                set winCount to 0
            end try

            -- 找到含注销标签的窗口索引；没有就完全不碰这个 Chrome
            set targetIdx to my findLogoutWindowIndex(p, winCount)
            if targetIdx > 0 then
                set frontmost of p to true
                try
                    perform action "AXRaise" of (window targetIdx of p)
                end try
                delay 0.3

                -- AXRaise 可能改变窗口顺序，重新定位
                try
                    set winCount to count of windows of p
                end try
                set targetIdx to my findLogoutWindowIndex(p, winCount)

                if targetIdx > 0 then
                    repeat
                        set tabs to {}
                        try
                            set tabs to my collectLogoutTabs(window targetIdx of p, 1)
                        on error
                            -- 窗口索引失效：重新定位，找不到就结束
                            try
                                set winCount to count of windows of p
                            end try
                            set targetIdx to my findLogoutWindowIndex(p, winCount)
                            if targetIdx is 0 then exit repeat
                        end try

                        if (count of tabs) is 0 then exit repeat
                        set t to item 1 of tabs
                        set nm to name of t
                        set base to my tabBaseTitle(nm)

                        set clicked to false
                        try
                            click t
                            set clicked to true
                        end try
                        delay 0.45

                        set wt to ""
                        try
                            set wt to name of window targetIdx of p
                        end try

                        if clicked and wt contains base then
                            keystroke "w" using command down
                            set closedCount to closedCount + 1
                            delay 0.4
                        else
                            -- 选中失败时绝不盲按 Cmd+W，避免误关其他标签
                            exit repeat
                        end if

                        if closedCount ≥ 200 then exit repeat
                    end repeat
                end if
            end if
        end repeat

        -- 焦点还给原应用（若还在运行）
        if prevName is not "" then
            try
                set frontmost of (first process whose name is prevName) to true
            end try
        end if
    end tell
    return closedCount
end closeLogoutTabs


-- 返回含注销标签的窗口索引；0 表示没有
on findLogoutWindowIndex(p, winCount)
    tell application "System Events"
        repeat with wi from 1 to winCount
            try
                if (count of my collectLogoutTabs(window wi of p, 1)) > 0 then
                    return wi
                end if
            end try
        end repeat
    end tell
    return 0
end findLogoutWindowIndex


-- ---------- 点掉「最近登录信息」窗口 ----------
on dismissLoginInfo()
    set dismissedCount to 0
    tell application "System Events"
        repeat with p in (every process whose name is "EasyConnect")
            try
                set winCount to count of windows of p
            on error
                set winCount to 0
            end try
            repeat with wi from 1 to winCount
                try
                    set w to window wi of p
                    set wn to name of w
                    if wn contains "登录信息" or wn contains "Login History" then
                        set target to my findConfirmButton(w, 1)

                        if target is missing value then
                            -- 兜底：窗口内最下方的按钮就是“确定”
                            set btns to my collectButtons(w, 1)
                            set maxY to -100000
                            repeat with b in btns
                                try
                                    set {bx, py} to position of b
                                    if py > maxY then
                                        set maxY to py
                                        set target to b
                                    end if
                                end try
                            end repeat
                        end if

                        if target is not missing value then
                            click target
                            set dismissedCount to dismissedCount + 1
                            delay 0.3
                        end if
                    end if
                end try
            end repeat
        end repeat
    end tell
    return dismissedCount
end dismissLoginInfo


-- ---------- 递归工具 ----------
on collectLogoutTabs(el, depth)
    set res to {}
    if depth > 14 then return res
    tell application "System Events"
        try
            set r to role of el
        on error
            return res
        end try
        if r is "AXRadioButton" then
            try
                set nm to name of el
                if nm contains "注销成功" or nm contains "por/logout" or nm contains "logout.csp" then
                    set end of res to el
                end if
            end try
            return res
        end if
        try
            set kids to every UI element of el
        on error
            return res
        end try
        repeat with c in kids
            set res to res & (my collectLogoutTabs(c, depth + 1))
        end repeat
    end tell
    return res
end collectLogoutTabs

on findConfirmButton(el, depth)
    set res to missing value
    if depth > 14 then return res
    tell application "System Events"
        try
            set r to role of el
        on error
            return res
        end try
        if r is "AXButton" then
            try
                set nm to name of el
                if nm is "确定" or nm is "OK" or nm is "好" or nm is "确定 " or nm is "OK " then
                    return el
                end if
            end try
        end if
        try
            set kids to every UI element of el
        on error
            return res
        end try
        repeat with c in kids
            set r2 to my findConfirmButton(c, depth + 1)
            if r2 is not missing value then return r2
        end repeat
    end tell
    return res
end findConfirmButton

on collectButtons(el, depth)
    set res to {}
    if depth > 14 then return res
    tell application "System Events"
        try
            set r to role of el
        on error
            return res
        end try
        if r is "AXButton" then
            set end of res to el
            return res
        end if
        try
            set kids to every UI element of el
        on error
            return res
        end try
        repeat with c in kids
            set res to res & (my collectButtons(c, depth + 1))
        end repeat
    end tell
    return res
end collectButtons

on tabBaseTitle(nm)
    set base to nm
    if nm contains " - Memory usage" then
        try
            set base to text 1 thru ((offset of " - Memory usage" in nm) - 1) of nm
        end try
    end if
    return base
end tabBaseTitle
