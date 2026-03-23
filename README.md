# Claude Sandbox

在 Docker 容器中安全地運行 `claude --dangerously-skip-permissions`，並透過 SSH 從 IDE（Zed / VS Code）遠端連入操作。支援多實例同時運行，每個實例可設定獨立的 CPU 和記憶體限制。

## 為什麼需要這個？

Claude Code 的 `--dangerously-skip-permissions` 會跳過所有確認提示，讓 Claude 自主執行任何指令。這在自動化工作流中很有用，但直接在主機上跑風險太大 — 一個 `rm -rf /` 就能毀掉整台機器。

**解法：把 Claude 關進 Docker 容器裡。** 容器就是沙箱，即使 Claude 搞壞了一切，也只影響容器，host 完全不受影響。

## 拓撲

```
Mac (Zed/VS Code) ──SSH ProxyJump──► Linux Server ──localhost:<port>──► Docker Container
                                                                         ├─ sshd
                                                                         ├─ tmux
                                                                         ├─ claude --dangerously-skip-permissions
                                                                         └─ /home/claude/workspace/
```

支援同時運行多個容器，各自獨立 port 和資源限制：

```
Linux Server
├─ claude-sandbox-project-a   (port 2222, 4 CPUs, 8GB)
├─ claude-sandbox-project-b   (port 2223, 4 CPUs, 8GB)
└─ claude-sandbox-heavy-job   (port 2224, 8 CPUs, 16GB)
```

## 文件導覽

| 文件 | 適合誰 | 內容 |
|------|--------|------|
| [docs/quickstart.md](docs/quickstart.md) | 新手 | 從零開始，一步步建置到可以用 |
| [docs/architecture.md](docs/architecture.md) | 有基礎的開發者 | 架構設計、設計決策、每個元件的職責 |
| [docs/concepts.md](docs/concepts.md) | 想深入學習的人 | SSH ProxyJump、Docker 網路、tmux 等核心概念 |

## 快速開始（給急性子的人）

```bash
# 在 Linux server 上
cd ~/Code/claude-sandbox

# 建立一個 sandbox 實例（預設 4 CPUs, 8GB RAM）
./setup.sh project-a

# 把專案丟進去、啟動 Claude
./launch-claude.sh project-a ~/Code/project-a

# 接上 Claude session
ssh -tt sandbox-project-a "bash -lic 'ta claude'"
```

多開一個：

```bash
./setup.sh project-b
./launch-claude.sh project-b ~/Code/project-b
ssh -tt sandbox-project-b "bash -lic 'ta claude'"
```

自訂資源限制：

```bash
SANDBOX_CPUS=8 SANDBOX_MEMORY=16g ./setup.sh heavy-job
```

詳細步驟請看 [quickstart.md](docs/quickstart.md)。

## 檔案結構

```
claude-sandbox/
├── Dockerfile          # 容器定義：Ubuntu 24.04 + sshd + Claude Code + Rust + uv + Bun
├── entrypoint.sh       # 容器啟動腳本：跑 sshd、保持容器存活
├── setup.sh            # 建置腳本：build image + 啟動實例 + 同步設定
├── launch-claude.sh    # 把專案送進指定實例 + 啟動 Claude
├── sync-back.sh        # 把容器內的檔案拉回 host（備用）
├── .instances/         # 實例 port 對照（gitignored，由 setup.sh 管理）
└── docs/
    ├── quickstart.md
    ├── architecture.md
    └── concepts.md
```
