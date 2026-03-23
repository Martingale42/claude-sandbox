# 快速上手指南

這份文件假設你：
- 有一台 Linux server（已裝 Docker）
- 有一台 Mac/Linux 本機，上面有 Zed 或 VS Code
- 本機可以 SSH 到 Linux server

如果你對 SSH、Docker 的原理不太熟，先看完這份跑起來，再去 [concepts.md](concepts.md) 補知識。

---

## 前置需求

在 Linux server 上確認以下工具已安裝：

```bash
docker --version   # Docker 20+ 即可
git --version
ssh -V
```

## Step 1：取得專案

```bash
# 在 Linux server 上
cd ~/Code
git clone <本專案的 repo URL> claude-sandbox
cd claude-sandbox
```

或者如果你已經有了：

```bash
cd ~/Code/claude-sandbox
```

## Step 2：執行 setup.sh

```bash
./setup.sh <instance-name>
```

例如：

```bash
./setup.sh project-a          # 建立名為 "project-a" 的 sandbox 實例
./setup.sh default            # 或用 "default"（不傳名稱也會用 default）
```

自訂資源限制（預設 4 CPUs, 8GB RAM）：

```bash
SANDBOX_CPUS=8 SANDBOX_MEMORY=16g ./setup.sh heavy-job
```

需要瀏覽器（前端開發、Playwright 截圖/操作）：

```bash
SANDBOX_BROWSER=1 ./setup.sh my-frontend
```

環境變數可以組合使用：

```bash
SANDBOX_BROWSER=1 SANDBOX_CPUS=8 SANDBOX_MEMORY=16g ./setup.sh my-frontend
```

這個腳本會自動完成以下事情（你不需要手動做）：

1. 產生一組 SSH key pair（存在 `claude-sandbox/.ssh/sandbox_key`，所有實例共用）
2. 用 Dockerfile build 出 Docker image（`base` 或 `browser` target）
3. 啟動 container `claude-sandbox-<name>`，自動分配 SSH port
4. 套用 CPU 和記憶體資源限制
5. 把你的 Claude 設定檔（skills、plugins、settings、credentials）和 tmux 設定複製進 container
6. 在 Linux server 的 `~/.ssh/config` 加一筆 `Host sandbox-<name>`

**執行完畢後，你在 Linux server 上就可以 `ssh sandbox-<name>` 直連 container 了。**

## Step 3：把專案送進 container

```bash
./launch-claude.sh <instance-name> ~/Code/你的專案名稱
```

例如：

```bash
./launch-claude.sh project-a ~/Code/project-a
```

這會：
1. 把整個專案目錄複製進 container 的 `/home/claude/workspace/`
2. 在 container 裡開一個 tmux session，自動執行 `claude --dangerously-skip-permissions`

## Step 4：接上 Claude session

### 方法 A：直接用終端機

```bash
# 在 Linux server 上
ssh -tt sandbox-project-a "bash -lic 'ta claude'"
```

你會看到 Claude 正在運行，可以直接跟它互動。

### 方法 B：從本機的 Zed 連進來（推薦）

這需要額外設定，讓你的 Mac 能直接 SSH 穿透 Linux server 到 container。

#### 4b-1. 把 sandbox 私鑰複製到 Mac

```bash
# 在 Mac 上執行（把 linux-server 換成你的 SSH host 名稱）
scp linux-server:~/Code/claude-sandbox/.ssh/sandbox_key ~/.ssh/claude-sandbox-key
chmod 600 ~/.ssh/claude-sandbox-key
```

#### 4b-2. 在 Mac 的 ~/.ssh/config 加入以下設定

你需要知道實例的 SSH port。在 Linux server 上可以查到：

```bash
cat ~/Code/claude-sandbox/.instances/project-a   # 例如輸出 2222
```

然後在 Mac 的 `~/.ssh/config` 加入：

```
Host sandbox-project-a
    HostName localhost
    Port 2222
    User claude
    IdentityFile ~/.ssh/claude-sandbox-key
    ProxyJump linux-server
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

> **linux-server** 要換成你平常 SSH 到 Linux server 用的 Host 名稱。
> Port 要換成實際分配的 port。

#### 4b-3. 測試連線

```bash
# 在 Mac 上
ssh sandbox-project-a echo "connected!"
```

看到 `connected!` 就成功了。

#### 4b-4. 用 Zed 連線

1. 打開 Zed
2. `Ctrl+Shift+P`（Mac 是 `Cmd+Shift+P`）
3. 搜尋 "ssh" 或 "Connect via SSH"
4. 選擇 `sandbox-project-a`
5. 開啟資料夾：`/home/claude/workspace/你的專案`
6. 打開 Terminal 面板（`` Ctrl+` ``）
7. 輸入：`ta claude`

現在你可以：
- 在 Zed 的檔案瀏覽器中看到 Claude 即時編輯的檔案
- 在 Terminal 中觀察或與 Claude 互動
- 用 Zed 自己開檔案、跑 language server 等

## Step 5：取回成果

### 正常流程（推薦）

Claude 在 container 裡 commit + push，你在 host 或 Mac 端 `git pull`。

### 備用方案

如果有 uncommitted 的東西需要撈回來：

```bash
# 在 Linux server 上
./sync-back.sh project-a 你的專案名稱                    # 預設拉到 ~/Code/專案名稱
./sync-back.sh project-a 你的專案名稱 /tmp/review        # 拉到指定位置
```

## 多實例使用

同時開多個 sandbox，各自跑不同專案：

### Linux server 端

```bash
# 建立多個實例
./setup.sh project-a                                       # base
SANDBOX_BROWSER=1 ./setup.sh project-b                     # 含瀏覽器
SANDBOX_CPUS=8 SANDBOX_MEMORY=16g ./setup.sh ml-training   # 自訂資源

# 各自送入專案
./launch-claude.sh project-a ~/Code/project-a
./launch-claude.sh project-b ~/Code/project-b

# 各自連入（從 Linux server terminal）
ssh -tt sandbox-project-a "bash -lic 'ta claude'"
ssh -tt sandbox-project-b "bash -lic 'ta claude'"

# 列出所有 sandbox 實例
docker ps --filter name=claude-sandbox-
```

### Mac 端（Zed / VS Code 遠端連入）

私鑰只需複製一次（Step 4b-1），所有實例共用同一把 key。

每新增一個實例，需要在 Mac 的 `~/.ssh/config` 加一筆對應的 entry。先在 Linux server 上查 port：

```bash
cat ~/Code/claude-sandbox/.instances/project-b   # 例如輸出 2223
```

然後在 Mac 的 `~/.ssh/config` 加入：

```
# BEGIN sandbox-project-b
Host sandbox-project-b
    HostName localhost
    Port 2223
    User claude
    IdentityFile ~/.ssh/claude-sandbox-key
    ProxyJump linux-server
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
# END sandbox-project-b
```

> **linux-server** 換成你 SSH 到 Linux server 用的 Host 名稱。
> **Port** 換成 `.instances/<name>` 裡的實際值。
> **IdentityFile** 用你在 Step 4b-1 複製私鑰時存放的路徑。

每個實例重複一次這個步驟。之後就能在 Zed/VS Code 裡選擇對應的 host 連入。

## 常用操作速查

以下指令中 `<name>` 替換為你的實例名稱（如 `project-a`、`default`）。

| 操作 | 指令 |
|------|------|
| 重新啟動 container | `docker restart claude-sandbox-<name>` |
| 看 container log | `docker logs claude-sandbox-<name>` |
| 進 container bash | `ssh sandbox-<name>` |
| 列出 tmux sessions | `ssh -tt sandbox-<name> "bash -lic 'tl'"` |
| 砍掉 tmux session | `ssh sandbox-<name> tmux kill-session -t claude` |
| 停止 container | `docker stop claude-sandbox-<name>` |
| 完全移除 container | `docker rm -f claude-sandbox-<name>` |
| 重新 build | `./setup.sh <name>`（會自動砍掉舊的再建） |
| 列出所有實例 | `docker ps --filter name=claude-sandbox-` |

## 常見問題

### Q: tmux 快捷鍵都被外層攔截了？

如果你在 host 的 tmux 裡 SSH 進 container 的 tmux，會有兩層 tmux 嵌套，prefix key（`Ctrl+B`）永遠被外層先收到。

**解法：按兩次 prefix，第二次會送進內層。**

| 操作 | 外層 tmux | 內層 tmux（container） |
|------|-----------|----------------------|
| 新窗口 | `C-b c` | `C-b C-b c` |
| 切窗口 | `C-b 1` | `C-b C-b 1` |
| 水平分割 | `C-b \|` | `C-b C-b \|` |
| 垂直分割 | `C-b -` | `C-b C-b -` |
| detach | `C-b d` | `C-b C-b d` |

原理：tmux 的 `send-prefix` 功能會把 `C-b C-b` 轉發一個 `C-b` 到內層。

### Q: setup.sh 跑到一半 SSH 連不上？

等久一點。sshd 啟動需要幾秒，腳本會自動重試最多 10 次。如果還是不行：

```bash
docker logs claude-sandbox-<name>    # 看有沒有錯誤訊息
docker exec -it claude-sandbox-<name> bash  # 手動進去看
```

### Q: Claude 的 credentials 過期了？

重新跑 launch-claude.sh，它會自動重新同步 credentials。或者手動：

```bash
docker cp ~/.claude/.credentials.json claude-sandbox-<name>:/home/claude/.claude/.credentials.json
docker exec claude-sandbox-<name> chown claude:claude /home/claude/.claude/.credentials.json
```

### Q: 想在同一個實例裡跑多個 Claude session？

用不同的 tmux session 名稱：

```bash
./launch-claude.sh project-a ~/Code/project-a session-a
./launch-claude.sh project-a ~/Code/project-b session-b
```

Attach 時指定名稱：`ta session-a`

### Q: Claude 裡面看不到 skills？

大概率是 `docker cp` 的目錄巢狀問題。確認一下：

```bash
ssh sandbox-<name> "ls ~/.claude/skills/ | head -5"
```

如果看到的是一個 `skills` 目錄（而不是 `adapt`、`animate` 等），代表多了一層。修復：

```bash
docker exec claude-sandbox-<name> rm -rf /home/claude/.claude/skills
docker cp ~/.claude/skills claude-sandbox-<name>:/home/claude/.claude/skills
docker exec claude-sandbox-<name> chown -R claude:claude /home/claude/.claude/skills
```

重跑 `./setup.sh <name>` 也能修復（已內建此修正）。

### Q: 怎麼查看某個實例分配到的 port？

```bash
cat ~/Code/claude-sandbox/.instances/<name>
# 或
docker port claude-sandbox-<name>
```
