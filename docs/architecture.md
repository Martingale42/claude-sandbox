# 架構設計

這份文件面向有 Docker/SSH/Linux 基礎的開發者，解釋每個元件的設計決策。

---

## 整體拓撲

```
┌─ Mac (本機) ──────────────────────────────────────────────────────────┐
│                                                                       │
│  Zed IDE ─── SSH (ProxyJump) ─────────────────────────────────┐      │
│                                                                │      │
│  ~/.ssh/config:                                                │      │
│    Host sandbox-project-a                                          │      │
│      ProxyJump linux-server  ◄── 透過 Linux server 跳轉        │      │
│      Port <auto-assigned>                                      │      │
└────────────────────────────────────────────────────────────────┼──────┘
                                                                 │
┌─ Linux Server ─────────────────────────────────────────────────┼──────┐
│                                                                │      │
│  Docker Host                                                   │      │
│  ┌─ claude-sandbox-project-a ─────────────────────────────────┐    │      │
│  │  (--cpus=4 --memory=8g)                                │    │      │
│  │  sshd (:22) ◄── port-forward ◄── host :<port> ◄───────┘    │      │
│  │    └──► claude user                                         │      │
│  │          ├─ tmux session "claude"                           │      │
│  │          │   └─ claude --dangerously-skip-permissions       │      │
│  │          ├─ ~/.claude/ (skills, plugins, settings, creds)   │      │
│  │          ├─ ~/.cargo/bin/ (rustc, cargo)                    │      │
│  │          ├─ ~/.bun/bin/ (bun)                               │      │
│  │          ├─ ~/.local/bin/ (claude, uv)                      │      │
│  │          └─ ~/workspace/project/                            │      │
│  └─────────────────────────────────────────────────────────────│      │
│  ┌─ claude-sandbox-project-b (browser) ────────────────┐   │      │
│  │  (--cpus=4 --memory=8g)                                │   │      │
│  │  ...（同上結構）                                        │   │      │
│  │  + Chromium + Playwright (SANDBOX_BROWSER=1)           │   │      │
│  └────────────────────────────────────────────────────────┘   │      │
└───────────────────────────────────────────────────────────────────────┘
```

## 多實例設計

### 命名與 port 分配

每個實例透過一個 `<name>` 參數識別：

```
./setup.sh <name>     →  Container: claude-sandbox-<name>
                          SSH Host:  sandbox-<name>
                          Port:      auto-assigned (stored in .instances/<name>)
```

Port 分配策略：從 2222 開始遞增，自動尋找下一個可用 port。分配結果儲存在 `.instances/<name>` 檔案中，重新 setup 同名實例會複用原 port。

### 資源限制與 image 選擇

透過環境變數覆蓋預設值：

| 環境變數 | 預設值 | 說明 |
|----------|--------|------|
| `SANDBOX_CPUS` | `4` | CPU 核心數限制 |
| `SANDBOX_MEMORY` | `8g` | 記憶體限制 |
| `SANDBOX_BROWSER` | `0` | 設為 `1` 啟用 Chromium + Playwright |

```bash
# 例：分配 8 CPUs 和 16GB RAM
SANDBOX_CPUS=8 SANDBOX_MEMORY=16g ./setup.sh heavy-job

# 例：含瀏覽器的前端開發實例
SANDBOX_BROWSER=1 ./setup.sh my-frontend
```

CPU/Memory 底層使用 Docker 的 `--cpus` 和 `--memory` 參數，映射到 Linux cgroups v2 資源控制。

### 共享資源

所有實例共用：
- **Docker image**：`claude-sandbox`（base）或 `claude-sandbox-browser`（含瀏覽器），Docker layer cache 共享 base 層
- **SSH key pair**：`.ssh/sandbox_key`，所有實例的 authorized_keys 都指向同一把公鑰
- **Host 的 Claude 設定**：每個實例獨立複製一份（setup 時 snapshot）

## 設計決策

### 為什麼用 SSH 而不是 docker exec？

| | SSH | docker exec |
|---|---|---|
| Zed Remote 支援 | 原生支援 | 不支援 |
| VS Code Remote 支援 | 原生支援 | 需另裝 Dev Containers 擴充 |
| 從外部機器連入 | ProxyJump 即可 | 需要 Docker API 暴露（安全風險大） |
| tmux 支援 | 完整 | 部分（tty 分配問題） |

SSH 是唯一能讓 Zed Remote 直連 container 的方式。`docker exec` 無法被 Zed 當作 remote target。

### 為什麼是 snapshot（docker cp）而不是 bind mount？

```bash
# 目前的做法：snapshot
docker cp ~/Code/project claude-sandbox-project-a:/home/claude/workspace/

# 另一種做法：bind mount
docker run -v ~/Code/project:/home/claude/workspace/project ...
```

**選擇 snapshot 的理由：**

- 沙箱的核心價值就是隔離。bind mount 讓 Claude 直接操作 host 檔案，一個 `rm -rf` 就穿透了
- Claude 改完後透過 git push 同步回來，這是正常的 git workflow
- 如果用 bind mount，Claude 的 file watcher 和 host 的 IDE 會同時操作同一份檔案，可能有 race condition

**什麼時候該用 bind mount：**

- 你信任 Claude 不會亂刪檔案，只想隔離 bash 指令的破壞力
- 你需要即時看到檔案變化而不想等 git round-trip

如需 bind mount，自行修改 `launch-claude.sh` 或用 `docker run -v` 掛載。

### 為什麼在 container 裡裝 Claude 而不是從 host 掛載進去？

Claude Code 原生二進制檔約 237MB，裝在 image 裡：

- **可重現**：任何人 build 都得到一致的環境
- **版本獨立**：container 裡的 Claude 版本不受 host 更新影響
- **乾淨**：不用煩惱 host 和 container 的 library 差異（glibc 版本等）

缺點是 image 比較大，但這是一次性成本。

### credentials 為什麼用 docker cp 而不是 build 進 image？

```dockerfile
# 絕對不要這樣做
COPY .credentials.json /home/claude/.claude/.credentials.json
```

credentials 寫進 image layer 就會永久存在於 image 歷史中，即使後來刪掉也能透過 `docker history` 還原。用 `docker cp` 在 runtime 注入，container 被砍掉 credentials 就消失了。

### SSH key 的生命週期

```
setup.sh 產生 key pair（首次才產生，之後共用）
    │
    ├── .ssh/sandbox_key       ← 私鑰，留在 host（或複製到 Mac）
    └── .ssh/sandbox_key.pub   ← 公鑰，掛載到所有實例的 authorized_keys
```

- key pair 是 **per-sandbox-project** 的，不會汙染你的個人 SSH key
- 所有實例共用同一組 key pair — 簡化管理，安全性不受影響（都是你的 sandbox）
- 公鑰以 `:ro`（read-only）方式掛載到 container，container 無法改它
- 如果需要 rotate key：刪掉 `.ssh/` 目錄，重跑 `setup.sh`

### Port 分配策略

```
.instances/
├── project-a       → 內容: 2222
├── project-b       → 內容: 2223
└── heavy-job       → 內容: 2224
```

- 首次 setup：從 2222 開始，掃描已占用和已分配的 port，取下一個可用的
- 重新 setup 同名實例：複用之前的 port（SSH config 不需更新）
- Port 紀錄存在 `.instances/` 目錄，gitignored（每台機器的分配可能不同）

### SSH config 管理

每個實例在 `~/.ssh/config` 中用 marker 包裹：

```
# BEGIN sandbox-project-a
Host sandbox-project-a
    HostName localhost
    Port 2222
    ...
# END sandbox-project-a
```

重新 setup 同名實例時，sed 會先移除舊 marker 區塊再寫入新的，避免重複。

## 元件職責

### Dockerfile（multi-stage）

Dockerfile 使用 Docker multi-stage build，定義兩個 named target：

```
base    ← 完整開發環境（預設）
browser ← 繼承 base，加裝 Chromium + Playwright
```

`docker build --target base` 或 `docker build --target browser` 選擇要 build 哪個。`setup.sh` 透過 `SANDBOX_BROWSER` 環境變數自動處理。

#### base stage

| 層 | 職責 |
|----|------|
| System packages | 基礎工具鏈（git、ripgrep、python3、build-essential、unzip 等） |
| Locale | 確保 UTF-8，避免中文/特殊字元亂碼 |
| claude user | 隔離權限，不以 root 跑 Claude |
| sshd config | 最小暴露面：只允許 key auth、只允許 claude user |
| Rust toolchain | `rustup` 安裝，提供 `rustc`、`cargo` |
| uv | Python 套件管理器，取代 pip/venv 的現代方案 |
| Bun | JavaScript runtime/bundler，用於前端編譯和開發伺服器 |
| Claude Code | 原生二進制檔（`curl https://claude.ai/install.sh`），不依賴 Node.js |
| `/etc/environment` | 系統層級 PATH 設定，確保所有 SSH 模式都能找到工具（見下方說明） |
| 目錄結構 | 預建 `.claude/`、`.ssh/`、`workspace/`，避免 runtime 權限問題 |

#### browser stage

| 層 | 職責 |
|----|------|
| Chromium 系統依賴 | `libnss3`、`libgbm1`、`libasound2t64` 等 headless Chromium 所需的系統函式庫 |
| Playwright + Chromium | `bunx playwright install chromium`，預裝 headless Chromium 瀏覽器 |

browser stage 繼承 base 的所有內容，額外增加約 900MB。兩個 image 共享 base layer，不會佔兩倍磁碟空間。

Claude 在 browser 版實例中可以透過 Playwright MCP：
- 開啟前端頁面、填寫表單、點擊按鈕
- 截圖確認 UI 排版
- 自動化瀏覽器測試流程

### entrypoint.sh

```
ssh-keygen -A     # 首次啟動才跑，產生 sshd host key
/usr/sbin/sshd    # daemon mode，背景執行
tail -f /dev/null # 讓 PID 1 永遠存活，container 不會退出
```

為什麼不用 `sshd -D`（foreground mode）？因為未來如果要在 entrypoint 加其他初始化邏輯（例如自動啟動 Claude），用 daemon mode + tail 比較彈性。

### setup.sh

建置腳本，冪等設計 — 重複跑不會壞：
- SSH key 已存在就跳過
- Docker image 自動使用 cache
- container 已存在就先砍再建
- Port 已分配就複用
- SSH config 用 marker 確保可覆寫

接受一個 `<name>` 參數（預設 `default`），支援 `SANDBOX_CPUS`、`SANDBOX_MEMORY` 和 `SANDBOX_BROWSER` 環境變數。根據 `SANDBOX_BROWSER` 選擇 build target（`base` 或 `browser`）和對應的 image tag。

#### docker cp 的目錄陷阱

```bash
# 如果 /home/claude/.claude/skills/ 已存在（Dockerfile mkdir 建的）
docker cp ~/.claude/skills container:/home/claude/.claude/skills
# 結果：/home/claude/.claude/skills/skills/  ← 巢狀了！

# 正確做法：先刪再複製
docker exec container rm -rf /home/claude/.claude/skills
docker cp ~/.claude/skills container:/home/claude/.claude/skills
# 結果：/home/claude/.claude/skills/adapt, skills/animate, ...  ← 正確
```

`docker cp SRC DEST` 的行為：如果 `DEST` 已存在且是目錄，會把 `SRC` 放進 `DEST` 裡面（類似 `mv`），而不是覆蓋。這跟 `cp -r` 的行為不同。

### launch-claude.sh

每次要開新專案時跑。接受 `<instance-name>` 和 `<project-path>` 兩個參數。設計上：
- 每次都重新 sync credentials（處理 token 輪替）
- tmux session name 可自訂，支援多個 Claude 同時跑
- 用 `ssh` 而不是 `docker exec` 來啟動 tmux — 確保 tty 和環境變數正確
- 自動將 HTTPS git remotes 轉為 SSH（配合 agent forwarding）

### 為什麼用 /etc/environment 而不是 .bashrc？

Rust、uv、Bun、Claude Code 都裝在使用者目錄（`~/.cargo/bin`、`~/.bun/bin`、`~/.local/bin`），不在系統預設的 PATH 裡。我們需要確保 SSH 連入時能找到這些工具。

SSH 有多種 shell 模式，各自讀不同的設定檔：

| 模式 | 觸發方式 | 讀 `.profile` | 讀 `.bashrc` |
|------|----------|:---:|:---:|
| 互動式 login shell | `ssh host` | O | O |
| 互動式 non-login | `ssh host` 後開新 bash | X | O |
| 非互動式 | `ssh host "command"` | X | X |

`launch-claude.sh` 用的是非互動式模式（`ssh sandbox-<name> "tmux new-session ..."`），這時 `.bashrc` 和 `.profile` 都不會被讀取。

**解法：** `/etc/environment` 是 PAM（Pluggable Authentication Module）層級的設定，不管什麼 shell 模式，只要透過 PAM 認證（SSH 就是），都會載入。所以我們把 PATH 寫在這裡。

我們也在 `.bashrc` 和 `.profile` 留了一份，作為互動式 shell 的雙重保險。

## 安全模型

```
風險層級圖：

Host filesystem     ██████████  完全隔離（snapshot 模式）
Host network        ████░░░░░░  container 可以存取（git push 需要）
Host Docker socket  ██████████  未掛載（Claude 不能操作其他 container）
Container 內部      ░░░░░░░░░░  Claude 有完全控制權（這是設計意圖）
CPU / Memory        ████████░░  受 cgroups 限制（預設 4 CPUs, 8GB）
```

**Claude 在 container 裡能做的事：**
- 讀寫 `/home/claude/` 下所有檔案
- 安裝套件（有 sudo）
- 執行任意 bash 指令
- 網路存取（git clone/push、cargo install、uv pip install、curl 等）
- 操作 headless Chromium（僅 browser 版：截圖、表單填寫、Playwright 自動化）

**Claude 做不到的事：**
- 存取 host filesystem（除非你用了 bind mount）
- 操作其他 Docker container（未掛載 docker.sock）
- 影響 host 的 SSH key 或 credentials（是 copy 不是 mount）
- 使用超過資源限制的 CPU 或記憶體

## 擴展方向

### 網路隔離

如果你想進一步限制 Claude 的網路存取：

```bash
# 建立隔離網路，只允許特定連線
docker network create --internal claude-net
docker run --network claude-net ...
```

但這會讓 git push 和 pip install 失效，需要設定 proxy。

### GPU passthrough

如果 Claude 需要跑 ML 相關工具：

```bash
docker run --gpus all ...
```

需要 host 有 NVIDIA Container Toolkit。
