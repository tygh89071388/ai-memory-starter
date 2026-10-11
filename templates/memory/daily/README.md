# Daily Journal

每次 Codex 完成一輪回覆，`journal-stop` hook 會把使用者原話、助理最終回覆和使用過的工具追加到 `YYYY-MM-DD.md`。

每輪固定使用六個欄位：`[情境]`、`[動作/決策]`、`[結果]`、`[教訓]`、`[落地]`、`[召回鍵]`。Hook 只保存可驗證資料，不用第二個 AI 自動推論教訓；語意整理交給 `memory-organizer`。

日記是 append-only 原始紀錄，不在這裡重寫歷史。週末由 `memory-organizer` 萃取重要內容到 `long-term/`。
