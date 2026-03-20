# 核心概念

這份文件為你補充 claude-sandbox 背後的技術知識。如果你已經跑起來了但想搞懂原理，從這裡開始。

---

## 目錄

1. [Docker 容器如何隔離](#1-docker-容器如何隔離)
2. [SSH 連線與 ProxyJump](#2-ssh-連線與-proxyjump)
3. [tmux：終端機多工器](#3-tmux終端機多工器)
4. [Docker 網路與 Port Forwarding](#4-docker-網路與-port-forwarding)
5. [Shell 環境與 PATH 載入](#5-shell-環境與-path-載入)
6. [Claude Code 的權限模型](#6-claude-code-的權限模型)

---

## 1. Docker 容器如何隔離

### 容器 ≠ 虛擬機

很多人把 Docker 容器想成輕量虛擬機，但它們本質不同：

```
虛擬機：
┌─────────────┐  ┌─────────────┐
│   App A     │  │   App B     │
│   Guest OS  │  │   Guest OS  │  ← 各自一套完整 OS
│   Hypervisor│  │   Hypervisor│
└──────┬──────┘  └──────┬──────┘
       └────────┬───────┘
           Host OS

容器：
┌─────────────┐  ┌─────────────┐
│   App A     │  │   App B     │
│ (isolated)  │  │ (isolated)  │  ← 共用 host kernel
└──────┬──────┘  └──────┬──────┘
       └────────┬───────┘
        Docker Engine
           Host OS
```

容器透過 Linux kernel 的兩個機制實現隔離：

- **Namespaces**：讓容器有自己的 PID、網路、檔案系統、hostname，看不到 host 的其他 process
- **Cgroups**：限制容器能用多少 CPU、記憶體

### 這對 claude-sandbox 的意義

在容器裡跑 `rm -rf /`：

- **容器的 `/`** 會被清空 → 容器壞掉
- **Host 的 `/`** 完全不受影響

這就是為什麼我們可以放心地讓 Claude 用 `--dangerously-skip-permissions`。最壞情況就是容器被搞壞，`docker rm -f` 砍掉重來。

### 容器的「可拋棄性」

容器應該被當成可拋棄的。你可以隨時：

```bash
docker rm -f claude-sandbox   # 砍掉
./setup.sh                     # 3 分鐘後又是一個全新的環境
```

所以我們把有價值的產出（程式碼）用 git push 送出去，而不是存在容器裡。

### docker cp 的行為跟你想的不一樣

`docker cp` 複製目錄時有一個常見陷阱：

```bash
# host 上有 ~/.claude/skills/adapt, skills/animate, ...
# container 裡 Dockerfile 已經 mkdir -p 了 ~/.claude/skills/

docker cp ~/.claude/skills container:/home/claude/.claude/skills
# 你以為：skills/adapt, skills/animate, ...
# 實際上：skills/skills/adapt, skills/skills/animate, ...  ← 多了一層！
```

當目的地目錄**已存在**時，`docker cp` 把來源目錄**放進去**而不是覆蓋。跟 `cp -r` 不同，更像 `mv`。

**解法：** 複製前先刪掉目的地目錄。

```bash
docker exec container rm -rf /home/claude/.claude/skills
docker cp ~/.claude/skills container:/home/claude/.claude/skills
```

---

## 2. SSH 連線與 ProxyJump

### SSH 基礎

SSH（Secure Shell）在兩台機器間建立加密通道。基本連線：

```bash
ssh user@hostname
```

### 金鑰認證 vs 密碼認證

```
密碼認證：
Client ──── "我是 claude，密碼是 xxx" ────► Server
                                            └─ 驗證密碼

金鑰認證：
1. 事先把公鑰放到 Server 的 authorized_keys
2. Client ──── "我是 claude，用這把私鑰簽名" ────► Server
                                                   └─ 用公鑰驗證簽名
```

金鑰認證更安全因為：
- 私鑰永遠不會傳輸到網路上（只傳簽名）
- 不怕暴力破解密碼
- 可以無密碼自動登入（給腳本和 IDE 用）

在 claude-sandbox 裡，`setup.sh` 會產生一組專用 key pair：

```
sandbox_key      ← 私鑰（留在你控制的機器上）
sandbox_key.pub  ← 公鑰（放進容器的 authorized_keys）
```

### ProxyJump：SSH 跳板

你的實際情況：

```
Mac ──✗──► Docker Container (localhost:2222 on Linux server)
```

Mac 沒辦法直接連 Linux server 的 `localhost:2222`，因為 `localhost` 對 Mac 來說是 Mac 自己。

**ProxyJump 解法：**

```
Mac ──SSH──► Linux Server ──SSH──► Container:2222
     (跳板)
```

在 `~/.ssh/config` 裡：

```
Host claude-sandbox
    HostName localhost          ← 目的地（從 Linux server 的角度看）
    Port 2222
    User claude
    ProxyJump linux-server      ← 先跳到這裡
```

SSH 會自動：
1. 先連到 `linux-server`
2. 在 `linux-server` 上建立到 `localhost:2222` 的連線
3. 把兩段連線串起來，你感覺像直接連到 container

**Zed 和 VS Code 都理解 ProxyJump**，所以 IDE 可以一步直連 container，不需要手動跳兩次。

### 更早期的做法（了解即可）

ProxyJump 是 OpenSSH 7.3+（2016）加的簡化語法。在那之前要用：

```
Host claude-sandbox
    ProxyCommand ssh -W %h:%p linux-server
```

效果一樣，但語法醜。如果你的 SSH 版本很舊才需要用這個。

---

## 3. tmux：終端機多工器

### 問題：SSH 斷了，程式就死了

正常情況下，你 SSH 到一台機器跑一個長時間程式，SSH 一斷（網路問題、筆電蓋上），程式就被 kill 了。

### tmux 的解法

tmux 在 server 端建立一個「session」，程式跑在 session 裡而不是跑在 SSH 連線裡：

```
沒有 tmux：
SSH 連線 ─── bash ─── claude
    │ (斷線)
    └──► bash 被 kill ──► claude 被 kill

有 tmux：
SSH 連線 ─── tmux client
    │              │
    │         tmux server ─── bash ─── claude
    │ (斷線)       │
    └──►           │ (tmux server 還活著)
                   └─── bash ─── claude (繼續跑)
```

### 常用操作

```bash
# 建立新 session
tmux new -s claude

# 離開 session（不是關掉，程式繼續跑）
# 按 Ctrl+B 再按 D

# 重新接上
tmux attach -t claude

# 列出所有 session
tmux ls

# 砍掉 session
tmux kill-session -t claude
```

### 在 claude-sandbox 裡的角色

`launch-claude.sh` 把 Claude 跑在 tmux 裡，所以：

- Zed 連上來，開 terminal，`tmux attach` 就能看到 Claude
- 關掉 Zed，Claude 不會停
- 手機 SSH 上去也能 `tmux attach` 看 Claude 在幹嘛
- 多個人可以同時 `tmux attach` 看同一個 session（pair programming）

### tmux 嵌套：兩層 tmux 共存

如果你在 host 的 tmux 裡 SSH 進 container，就會有兩層 tmux：

```
外層 tmux (host)
└─ SSH 到 container
   └─ 內層 tmux (container)
      └─ Claude session
```

兩層都用 `Ctrl+B` 作為 prefix，外層永遠先攔截。怎麼操作內層？

**按兩次 prefix：**

```
Ctrl+B → 外層收到，等待下一個按鍵
Ctrl+B → 外層透過 send-prefix 轉發一個 Ctrl+B 給內層
c      → 內層收到，建立新窗口
```

這是 tmux 的內建機制：`send-prefix`。當你按 `prefix prefix`，第一個被外層消費，第二個被當作輸入轉發給內層程式。因為內層程式也是 tmux，它就把這個 `Ctrl+B` 當成自己的 prefix。

如果你覺得雙按太麻煩，也可以改內層 tmux 的 prefix（例如 `Ctrl+A`），但這需要維護兩份不同的 `.tmux.conf`。

### tmux 設定檔

容器裡的 tmux 設定是從 host 複製過去的（`~/.tmux.conf`）。本專案的設定包含：

- 滑鼠支援（可以用滑鼠選 pane）
- `|` 和 `-` 分割視窗（比預設的 `%` 和 `"` 直覺）
- `Alt+方向鍵` 切換 pane（不用按 prefix）
- OSC 52 剪貼簿支援（跨 SSH 複製文字回本機）

---

## 4. Docker 網路與 Port Forwarding

### 容器的網路是隔離的

每個容器有自己的網路 namespace，有自己的 IP 位址（通常是 `172.17.x.x`）。

```bash
# 從 host 看
$ docker inspect claude-sandbox | grep IPAddress
"IPAddress": "172.17.0.5"
```

但你不會直接用這個 IP，因為它是 Docker 內部網路。

### Port Forwarding（-p 參數）

```bash
docker run -p 2222:22 ...
```

這告訴 Docker：「host 的 port 2222 收到的流量，轉發到容器的 port 22。」

```
外部 ──► host:2222 ──► (Docker NAT) ──► container:22 (sshd)
```

所以 `ssh -p 2222 claude@localhost` 實際上是連到容器裡的 sshd。

### 容器對外的存取

預設情況下，容器可以主動連外（outbound），不能被動接受連線（inbound，除非有 -p）。

在 claude-sandbox 裡：

| 方向 | 狀態 | 用途 |
|------|------|------|
| 外 → 容器 | 只開 port 22（映射到 host:2222） | SSH/Zed 連入 |
| 容器 → 外 | 完全開放 | git push、pip install、curl 等 |

---

## 5. Shell 環境與 PATH 載入

這是我們在建置 claude-sandbox 時實際踩到的坑，值得詳細說明。

### 問題

Rust（`~/.cargo/bin`）、uv（`~/.local/bin`）、Claude Code（`~/.local/bin`）都裝在使用者的 home 目錄下，不在系統預設的 PATH 裡。如果 PATH 沒設好，SSH 進去後打 `claude` 會得到 `command not found`。

你可能會想：「放進 `.bashrc` 不就好了？」但 SSH 有不同的 shell 模式，各自讀不同的設定檔。

### Linux shell 的啟動類型

```
                     ┌─ login shell ─────► 讀 /etc/profile → ~/.profile
                     │                     （~/.profile 通常會 source ~/.bashrc）
bash 啟動 ──────────┤
                     │                     ┌─ interactive ──► 讀 ~/.bashrc
                     └─ non-login shell ──┤
                                           └─ non-interactive ► 什麼都不讀 *
```

\* 除非設了 `BASH_ENV` 環境變數

### SSH 的 shell 模式對照

| 你怎麼連 | 模式 | 讀 `.profile` | 讀 `.bashrc` |
|----------|------|:---:|:---:|
| `ssh host` | 互動式 login shell | O | O（被 .profile source） |
| Zed terminal / VS Code terminal | 互動式 login shell | O | O |
| `ssh host "command"` | 非互動式 non-login | X | X |
| `ssh host "bash -lc 'command'"` | 強制 login shell | O | O |

關鍵的第三行：`launch-claude.sh` 用的就是 `ssh host "tmux new-session ..."` 這種模式。如果只把 PATH 寫在 `.bashrc`，這個指令就會找不到 `claude`。

### 解法：/etc/environment

```bash
# /etc/environment
PATH=/home/claude/.local/bin:/home/claude/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

`/etc/environment` 是 PAM（Pluggable Authentication Module）層級的設定。PAM 是 Linux 的認證框架，SSH 登入時會經過 PAM，PAM 的 `pam_env` 模組會讀 `/etc/environment` 並注入環境變數。

這發生在 shell 啟動之前，所以不管你用哪種 shell 模式，PATH 都已經設好了。

### 為什麼不用其他方案？

| 方案 | 結果 |
|------|------|
| Dockerfile 的 `ENV PATH=...` | 只影響 `docker build` 和 `docker exec`，SSH session 不繼承 |
| `~/.bashrc` | 非互動式 SSH 不讀 |
| `~/.profile` | 非 login shell 不讀 |
| `~/.ssh/environment` + `PermitUserEnvironment yes` | 理論上可行，但實測在 Ubuntu 24.04 的 sshd 上不穩定 |
| `/etc/environment` | 所有 PAM 認證的 session 都讀，最可靠 |

### 完整的防線

在 claude-sandbox 裡，我們設了三層：

1. `/etc/environment` — 涵蓋所有 SSH 模式（主力）
2. `~/.bashrc` — 互動式 shell 的保險
3. `~/.profile` — login shell 的保險

這是防禦式程式設計的實踐：不依賴單一機制，用多層覆蓋確保正確。

---

## 6. Claude Code 的權限模型

### 正常模式

Claude Code 預設每個動作都要你確認：

```
Claude 想要執行：rm -rf node_modules
[Allow] [Deny] [Allow Always]
```

這很安全但很慢，尤其你想讓 Claude 自主完成大型任務時。

### --dangerously-skip-permissions

加了這個 flag，Claude 會跳過所有確認，直接執行。這包括：

- 任意 bash 指令
- 讀寫任意檔案
- 安裝/移除套件
- Git 操作

**在你的主機上跑這個很危險。** 但在容器裡跑就很安全，因為「任意」的範圍被限縮到容器內部。

### Claude 的設定檔結構

```
~/.claude/
├── CLAUDE.md           ← 全域指示，影響 Claude 的行為
├── settings.json       ← 啟用的 plugins、權限設定
├── .credentials.json   ← API 認證 token
├── skills/             ← 自訂技能（slash commands）
│   ├── brainstorming/
│   ├── systematic-debugging/
│   └── ...
└── plugins/            ← 已安裝的 plugins
    ├── installed_plugins.json
    └── cache/
```

`setup.sh` 會把這整套複製進容器，所以容器裡的 Claude 跟你 host 上的 Claude 有完全相同的技能和設定。

### 容器內的開發工具鏈

除了 Claude Code 之外，容器還預裝了：

| 工具 | 安裝位置 | 用途 |
|------|----------|------|
| Rust (rustc, cargo) | `~/.cargo/bin/` | 編譯 Rust 專案 |
| uv | `~/.local/bin/` | 現代 Python 套件管理器，取代 pip + venv |
| Python 3 | `/usr/bin/` | 系統 Python，uv 會管理專案虛擬環境 |
| ripgrep (rg) | `/usr/bin/` | Claude Code 內部搜尋用 |
| git | `/usr/bin/` | 版本控制、推送成果 |

這些工具的 PATH 透過 `/etc/environment` 設定（原因見 [Shell 環境與 PATH 載入](#5-shell-環境與-path-載入)）。

### 為什麼 credentials 需要特別處理？

Claude 的 `.credentials.json` 包含 OAuth token，有時效性。如果 token 過期了，容器裡的 Claude 就無法認證。

`launch-claude.sh` 每次執行都會重新同步 credentials，就是為了處理這個問題。如果你長時間使用同一個 container，token 過期時需要手動重新同步：

```bash
docker cp ~/.claude/.credentials.json claude-sandbox:/home/claude/.claude/.credentials.json
docker exec claude-sandbox chown claude:claude /home/claude/.claude/.credentials.json
```

---

## 延伸閱讀

- [Docker 官方文檔：Container networking](https://docs.docker.com/network/)
- [SSH ProxyJump 完整說明](https://man.openbsd.org/ssh_config#ProxyJump)
- [tmux 入門教學（Pragmatic tmux）](https://pragmaticpineapple.com/gentle-guide-to-get-started-with-tmux/)
- [Claude Code 官方文檔](https://docs.anthropic.com/en/docs/claude-code)
