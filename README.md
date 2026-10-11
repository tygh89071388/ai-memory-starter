# AI 長期記憶入門包（ai-memory-starter）

**讓 AI 記得你糾正過的事。** 你糾正它一次，它自己記進日記；定期整理成一條條教訓；下次開工先讀教訓目錄，自己想起這輪該照做的規矩。

這是 [獨步天下秘密實驗室](https://www.uitwtw.com/) 雞群用了半年的記憶系統，抽出可以在一般人電腦上跑的部分開源出來。實驗過程、實測數字，以及最簡單的裝法，寫在這篇：

👉 **[AI 都不記得你的教訓？站長花半年自己做了一套記憶系統！](https://www.uitwtw.com/ai/ai-long-term-memory/)**

- 記憶全部是你電腦裡的純文字檔（Markdown），打得開、看得懂、改得動
- 換 AI 工具、換模型，記憶資料夾帶著走
- 主力支援 Windows＋Codex；Claude Code、Antigravity 等工具也能用（hook 由 AI 依各家官方格式幫你掛）
- 不需要任何付費 API

---

## 最簡單的裝法：把提示詞貼給 AI

打開你的 AI 工具（Codex 桌面版、Claude Code 等），把 [`prompts/一鍵安裝提示詞.txt`](prompts/一鍵安裝提示詞.txt) 裡「===複製從這裡開始===」到「===複製到這裡結束===」整段複製貼上送出。

AI 會一次只帶你做一步：先說這步要做什麼、為什麼，給你可以整段複製的指令，等你回報畫面才給下一步。過程中會需要你同意的權限、哪幾步一定要你本人按，提示詞裡都寫清楚了。

建議用該平台最聰明的模型來跑安裝；快速版模型可能不會完全照步驟走。

---

## 裝好之後你會有什麼

| 東西 | 在哪裡 | 做什麼 |
|---|---|---|
| 日記 | `memory\daily\YYYY-MM-DD.md` | 每輪對話結束自動把問答寫進當天日記，只往後加、不改舊的 |
| 長期記憶 | `memory\long-term\` | 整理日記後的人物、規則、教訓、專案等，一份一個檔 |
| 教訓目錄 | `memory\long-term\目錄.md` | 每份長期記憶一行，寫著「什麼時候該想起它」；整理時自動重建，AI 開工先讀 |
| 搜尋索引 | `.ai-assistant\qmd\` | 用 [qmd](https://github.com/tobi/qmd)＋multilingual-e5-large-instruct 在本機搜尋長期記憶，不上傳雲端 |
| 規則檔 | `AGENTS.md` | AI 每次開工都會讀的說明檔：身分、溝通偏好、工作流程、禁區、記憶使用 |

### 六個 hook（Codex 格式，安裝器會自動掛上）

hook 是「工具在固定時間點一定會執行的小程式」，不靠 AI 自己記得去做。

| hook | 什麼時候跑 | 做什麼 | 沒有它會怎樣 |
|---|---|---|---|
| `session-start` | 開新對話 | 載入近期日記脈絡 | AI 不知道最近發生什麼 |
| `journal-prompt` | 你送出訊息 | 暫存你的原話，準備寫日記 | 日記缺你的原始問題 |
| `memory-recall` | 你送出訊息 | 用 qmd 搜長期記憶，附上參考片段 | AI 要你提醒才想起舊事 |
| `journal-tool` | AI 用工具後 | 只記用了哪些工具，不塞完整輸出 | 日記少一層行為紀錄 |
| `danger-guard` | AI 執行指令前 | 攔下部分高風險刪除、關機指令 | 少一道輔助護欄（它不是完整的安全邊界） |
| `journal-stop` | 每輪結束 | 把問答寫進當天日記 | 日記完全不會長，等於沒有記憶來源 |

### 三個技能（`.agents\skills\`）

- **memory-organizer**：整理日記。把日記裡的定案、教訓、偏好搬進長期記憶，合併重複、修正記錯的，最後重建教訓目錄和搜尋索引。跟 AI 說「整理日記」就會啟動，建議每天或每週排程跑一次。
- **student-profile-interview**：第一次訪談。一題一題問你的背景、溝通偏好、禁區，確認後寫成 `AGENTS.md` 和人物記憶。跟 AI 說「開始學員訪談」就會啟動。
- **project-capsule**：專案交接卡。長期專案的目前定案、做到哪、下一步，讓新對話一打開就接得上。

---

## 平常怎麼用

- **糾正它就好**：講錯了直接糾正，或說「記住…」。這件事會先進日記，整理日記後變成長期記憶，目錄也跟著更新。
- **它有沒有照做，你用起來就知道**：AI 每次開工會先讀教訓目錄、自己挑出這輪要用的記憶打開來讀，不用列給你看。
- **想查以前的事，直接問**：像「上次那份報價是怎麼算的？」，它會先去長期記憶和日記裡找，找到會說是哪個檔，沒找到就說沒找到。
- **定期整理**：Claude Code 桌面版和 Codex（ChatGPT 桌面版）都有排程任務，設一個每天或每週跑一次「整理日記」就好。

### 為什麼是「教訓目錄」，不是每次都去搜尋？

我們拿 312 題真實對話實測過：用搜尋找記憶（不管是 qmd 或其他熱門記憶系統），該想起的規則只找得到一成多，因為你講的話跟該想起的規則常常長得不像；讓 AI 看整份目錄自己判斷，有五到六成。所以這裡兩個都留：目錄負責「這輪該照哪些規矩做」，搜尋負責「以前發生過什麼事」。詳細數字在上面那篇文章。

---

## 不用提示詞，自己手動裝

需要 Windows 10/11、PowerShell 5.1 以上、剩餘空間 3GB 以上。

```powershell
# 1. 建立並進入專案資料夾（路徑用雙引號包住）
New-Item -ItemType Directory -Force -Path "C:\Users\帳號\Documents\AI記憶" | Out-Null
Set-Location "C:\Users\帳號\Documents\AI記憶"
$project = (Get-Location).Path

# 2. 安裝 Node.js LTS，裝完關掉重開 PowerShell，再 Set-Location 回專案
winget install --id OpenJS.NodeJS.LTS
node --version   # 主版號要 >= 22

# 3. 安裝 qmd（版本要正確）
npm install -g @tobilu/qmd@2.5.3
qmd --version    # 要印出 2.5.3

# 4. 下載這個 repo 到暫存資料夾
$download = Join-Path $env:TEMP ("ai-memory-starter-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $download | Out-Null
Invoke-WebRequest -Uri "https://github.com/tygh89071388/ai-memory-starter/archive/refs/tags/v1.2.zip" -OutFile "$download\starter.zip"
Expand-Archive -Path "$download\starter.zip" -DestinationPath $download
$starter = (Get-ChildItem -LiteralPath $download -Directory | Select-Object -First 1).FullName

# 5. 先預覽，確認目標在 $project\.ai-assistant、畫面出現 No changes were made
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$starter\install.ps1" -Scope Project -WhatIf

# 6. 正式安裝骨架，再下載語意搜尋模型（約 2.5GB，畫面長時間沒動是正常的）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$starter\install.ps1" -Scope Project -SkipEmbedding
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$starter\scripts\download-embedding-model.ps1" -ProjectRoot $project

# 7. 用 Codex 桌面版關閉再重新開啟專案資料夾，逐一信任六個 hook（這步一定要本人按）

# 8. 跑安裝檢查器，要看到 0 failed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\.ai-assistant\scripts\verify-install.ps1 -ProjectRoot $project
```

裝完跟 AI 說「開始學員訪談」，建立你的 `AGENTS.md`。`AGENTS.md` 的記憶段要寫「開工前先讀 `<專案完整路徑>\memory\long-term\目錄.md`」，一律寫完整路徑，不要寫相對路徑。

### Claude Code 使用者

Claude Code 在資料夾裡有 `CLAUDE.md` 時就不會自己讀 `AGENTS.md`。在專案根目錄的 `CLAUDE.md` 寫這兩行，開工時就會直接載入（一律完整路徑、用正斜線）：

```text
@C:/Users/帳號/Documents/AI記憶/AGENTS.md
@C:/Users/帳號/Documents/AI記憶/memory/long-term/目錄.md
```

我們實測時發現，`@記憶/目錄.md` 這種中文開頭的相對路徑開工時不會被載入，改成完整路徑才正常。hook 部分請 AI 依 [Claude Code 官方 hook 文件](https://code.claude.com/docs/en/hooks-guide) 把上面六個 hook 翻成 Claude Code 的格式掛上。

---

## 常見問題

- **指令碼被停用／ExecutionPolicy 錯誤**：不要改全機原則，用上面帶 `-ExecutionPolicy Bypass` 的單次執行。
- **路徑含中文或空格出錯**：全程用雙引號包路徑；先 `Set-Location` 再安裝。
- **下載失敗（npm、模型、GitHub 逾時或 404）**：換穩定網路重跑同一條指令。模型只認 `hf:Ralriki/multilingual-e5-large-instruct-GGUF/multilingual-e5-large-instruct-q8_0.gguf`，不要換別顆。GitHub 被擋時，到本頁按「Code → Download ZIP」手動下載。
- **找不到 node／npm／qmd**：關掉所有 PowerShell 視窗重開再驗；node 要 22 以上。
- **qmd status 沒有 memory-longterm 或 Vectors=0**：骨架與模型腳本都要跑完；第一次查詢慢是模型還在載入，不是壞掉。
- **日記不長、記憶搜不到**：幾乎都是六個 hook 沒點完信任，或開錯資料夾。Codex 桌面版不支援 `/hooks` 指令，要用重新開啟資料夾的方式觸發信任提示。
- **裝錯資料夾**：不要再裝第二次。看安裝結束印出的 Hooks:／Memory: 才是真實位置，回正確資料夾先 `-WhatIf` 再重裝。
- **找不到 winget**：到 Microsoft Store 更新「應用程式安裝程式（App Installer）」再試。

---

## 想要有人陪你裝？

自己裝卡住、或想直接把它接進你的工作流程，可以看站長的 [養出懂你的 AI](https://www.uitwtw.com/shop/ai/)，由站長陪你一起裝好、幫你除錯。

## 授權

[MIT](LICENSE)
