# DCIC HW4 – QPSK / 16QAM 基頻接收器 (RTL)

## 專案簡介

本專案實作一個支援 QPSK 與 16QAM 的基頻接收器 (Baseband Receiver)，
並以模組化方式設計，使調變無關 (modulation-independent) 與
調變相關 (modulation-dependent) 模組清楚分離。

整體設計以 Verilog 撰寫，並考慮模組重用性與架構可擴展性。

---

## 架構設計說明

本設計將接收器分為兩大部分：

### 一、共用處理模組（rtl/common）

此資料夾包含 QPSK 與 16QAM 共同使用的基頻前端處理模組，例如：

- 64-point Radix-2 DIT FFT
- CP (Cyclic Prefix) 同步模組
- 核心訊號處理流程模組

設計理念為：

- 將與調變方式無關的訊號處理流程抽離
- 避免重複撰寫相同前端架構
- 提升模組重用性
- 方便未來擴充至更高階調變（例如 64QAM）

---

### 二、調變專屬模組

分別位於：

- rtl/qpsk/
- rtl/16qam/

此部分實作：

- Demapper 決策邏輯
- 調變專屬 symbol 判決
- 對應 top module

設計方式為：

> 共用前端處理流程不變，只替換 demap 階段。

因此 QPSK 與 16QAM 共用同一套 FFT 與同步架構，
僅在最後符號判決部分不同。

---

## 專案目錄結構

```
dcic_hw4/
├── spec/                  # 作業規格
├── exercise/
│   ├── rtl/
│   │   ├── common/        # 共用處理模組
│   │   ├── qpsk/          # QPSK 專屬模組
│   │   └── 16qam/         # 16QAM 專屬模組
│   ├── tb/                # 測試平台
│   └── result/            # 模擬輸出（未納入版本控制）
├── .gitignore
└── README.md
```
---

## 設計理念

本專案著重於架構層級的模組劃分，而非單純功能實作。

透過：

- 前端處理與 demap 分離
- 共用模組抽象化
- 模組化資料夾結構設計

達到：

- 維護性提升
- 架構清晰
- 可擴展性高
- 易於比較不同調變方式之硬體成本

---

## 合成與比較

針對 QPSK 與 16QAM 分別進行合成，
並比較其：

- Area
- Power
- 資源使用差異

由於兩者共用相同前端處理架構，
可清楚觀察不同 demap 複雜度對硬體成本的影響。

---

## 作者

彭冠傑