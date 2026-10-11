---
name: student-profile-interview
description: >
  安裝完成後，以一問一答方式建立使用者的 AGENTS.md 與人物長期記憶。只有使用者明確要求「開始學員訪談」「建立我的人設與人物記憶」時觸發。每次只問一題、允許跳過、禁止推測；全部回答完成後先給預覽，取得明確確認才直接寫入 AGENTS.md 與 memory/long-term/人物/自己.md。
---

# Student Profile Interview（安裝後第一次訪談）

> 這是整套記憶系統唯一允許「不經 daily 整理，直接寫入人物長期記憶」的流程。例外只限學員本人已逐項回答並確認的資料。

## 使用邊界

- 只處理目前專案的 `AGENTS.md` 與 `memory/long-term/人物/自己.md`。
- 不處理其他人物、專案、規則、設定或教訓記憶。
- 不修改或刪除 `memory/daily/`。
- 不詢問或保存密碼、token、憑證、私鑰、信用卡、身分證號、醫療病歷。
- 生日是選填；先問要保存「月日」還是「完整年月日」，不得自行擴大保存範圍。
- 飲食限制、關係與生活資料都可回答「跳過」；跳過就不寫。
- 使用者沒有親口確認的內容不得推測或從語氣推論。

## Step 0：先檢查現況

1. 確認目前專案已安裝完成（`verify-install.ps1` 顯示 0 failed）。
2. 讀取 `.ai-assistant/templates/AGENTS.example.md` 與 `.ai-assistant/templates/persona-template.md`。
3. 若 `AGENTS.md` 已存在，讀取後採合併模式，不可覆蓋。
4. 若 `memory/long-term/人物/自己.md` 已存在，讀取後採更新模式，不可丟失舊資料。
5. 告訴學員：總共 12 題、每次只問一題、任何題目都能回答「跳過」或「不知道」。

## Step 1：逐題訪談

嚴格一次只問一題。收到回答後，用一句話重述確認，再問下一題。不得一次貼出整份問卷。

1. 希望 AI 怎麼稱呼你？是否有不想被使用的稱呼？
2. 你目前的工作、科系或主要身分是什麼？
3. 你平常最常處理哪些工作或任務？
4. 你常用哪些軟體、平台、程式語言或設備？
5. 最近最想完成的三個目標是什麼？
6. 你的興趣、休閒活動或長期嗜好有哪些？
7. 你喜歡的食物、飲料與口味是什麼？
8. 有沒有希望推薦時避開的食物、飲料或口味？這題可以跳過。
9. 生日是否要讓 AI 記住？若要，保存月日還是完整年月日？
10. 有哪些重要人物或關係希望 AI 記住？只寫對方稱呼與關係，不要求敏感資料；可跳過。
11. 你偏好的回覆語言、長度、語氣與排版方式是什麼？
12. AI 協助工作時有哪些禁區、必須先詢問的動作或固定流程？

若回答模糊，只能追問當前題目一個澄清問題；澄清後再前進。

## Step 2：分流資料

把答案分成兩份草稿：

### AGENTS.md

只放每個新 session 都要遵守的操作規則：

- 稱呼與助理定位
- 溝通語言、長度、語氣、排版
- 常用工作流程
- trigger → action 規則
- 禁區與需要先詢問的動作

### 人物長期記憶

只放穩定的人物事實：

- 稱呼、工作或主要身分
- 常用工具
- 已確認的目標、興趣、飲食偏好
- 學員選擇保存的生日粒度
- 學員主動提供的重要人物與關係

不要把同一句操作規則完整複製到兩邊。AGENTS.md 管「怎麼做」，人物記憶管「學員是誰」。

## Step 3：寫入前確認

顯示兩份完整預覽，並列出：

- 將新增或更新的檔案
- 被跳過、不會保存的題目
- 你主動排除的敏感資訊或未確認推測

最後只問：

> 以上內容是否正確？請回答「確認寫入」或指出要修改的地方。

沒有收到完全相同意思的明確確認前，不得寫檔。

## Step 4：寫入 AGENTS.md

- 不存在：以 `persona-template.md` 的結構建立完成版，不保留 `[TODO]`。
- 已存在：保留原規則，合併新內容；衝突時列出並請學員裁決。
- 每條工作規則使用「觸發條件 → 明確動作 → 可觀察結果」。
- 不在 AGENTS.md 內放生日、喜歡吃什麼等百科資料。
- 記憶段的「開工先讀目錄」規則一定要寫進去，路徑換成這個專案在這台電腦上的完整路徑（例如用 `(Get-Location).Path` 取得專案根目錄再接 `\memory\long-term\目錄.md`），不能留 `[TODO]`，也不能寫相對路徑。

## Step 5：直接寫入人物記憶

目標：`memory/long-term/人物/自己.md`

```markdown
---
description: 學員本人已確認的背景、偏好、興趣、目標與重要關係
類型: 人物
狀態: 已驗證
建立日期: YYYY-MM-DD
最後更新: YYYY-MM-DD
來源: 學員訪談
關聯: []
標籤: [學員本人, 個人偏好]
---

## 摘要
- 使用一至三句話描述學員。

## 基本資料
- 希望稱呼：
- 工作／主要身分：

## 工作與工具
- ...

## 目標
- ...

## 興趣
- ...

## 飲食偏好
- 喜歡：
- 避開：

## 生日
- 只寫學員同意的粒度；未提供就省略本段。

## 重要人物與關係
- 只寫學員主動提供且同意保存的內容；沒有就省略本段。

## 溝通偏好
- ...

## 不確定或未保存
- 明列跳過與尚未確認的項目，避免未來 AI 腦補。

## 來源
- 人設與規範互動訪談 — YYYY-MM-DD（學員逐項確認）
```

## Step 6：更新 qmd 並驗收

```powershell
$project = (Get-Location).Path
$env:XDG_CACHE_HOME = "$project\.ai-assistant\qmd\cache"
$env:XDG_CONFIG_HOME = "$project\.ai-assistant\qmd\config"
$env:QMD_CONFIG_DIR = "$project\.ai-assistant\qmd\config\qmd"
$env:INDEX_PATH = "$project\.ai-assistant\qmd\cache\qmd\index.sqlite"

qmd update
if ($LASTEXITCODE -ne 0) { throw "qmd update failed" }

qmd embed -c memory-longterm
if ($LASTEXITCODE -ne 0) { throw "qmd embed failed" }

qmd query "學員的工作、興趣與飲食偏好" -c memory-longterm -n 5
if ($LASTEXITCODE -ne 0) { throw "qmd query failed" }
```

驗收：

- `AGENTS.md` 不含 `[TODO]`。
- `人物/自己.md` 只包含學員確認的內容。
- qmd query 命中 `人物/自己.md`。
- 提醒學員：關閉目前對話，開新對話測試它記不記得你。
