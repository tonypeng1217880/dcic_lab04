# DCIC HW4 – QPSK / 16QAM OFDM Baseband Receiver (RTL)

---

## 專案概述

本專案實作一套 **OFDM 基頻接收器 (Baseband Receiver)**，  
支援 **QPSK 與 16QAM** 調變方式，並以 **Verilog RTL** 完成硬體實現。

本設計重點包含：

- CP-based OFDM Symbol Synchronization
- 64-point Radix-2 DIT FFT
- Fixed-point (Q8.8) 設計
- QPSK / 16QAM Demapper
- RTL 與 C++ 模型比對驗證
- 合成與 PPA 分析

本專案為 C++ 模擬版本的硬體實現版本（Fixed-point Q8.8）。

---

# 系統架構

整體資料流如下：

```
Input Samples
    ↓
CP Autocorrelation Synchronization
    ↓
64-point FFT (Radix-2 DIT)
    ↓
Demapper (QPSK / 16QAM)
    ↓
Output Bitstream
```

---

# 一、OFDM Symbol Synchronization

## 設計方法

使用 CP-based Autocorrelation：

根據講義公式：

Φ_d 與 P_d 進行三維 summation（d, m, k）

- N = 64
- CP 長度 = 16
- 共 3 個 OFDM symbol

---

## 硬體架構特色

✔ 採用 FSM 控制 sequential 累加  
✔ 不使用大規模 combinational parallel 電路  
✔ 所有乘法與加法逐拍完成  
✔ 使用 40-bit accumulator 控制 overflow  

核心計算：

```
Phi_r += (ar*br + ai*bi)
Phi_i += (ai*br - ar*bi)
P_acc += (br*br + bi*bi)
```

---

## Multi-cycle Divider

- 使用 DesignWare `DW_div_seq`
- 分子左移 SCALE=16
- FSM 等待除法完成
- 輸出 gamma_out 與對應 d_out

---

## 驗證結果

QPSK 與 16QAM 均產生三組明顯 peak，  
Verilog 結果與 C++ 結果一致。


---

# 二、64-point FFT 設計

## 演算法

- Radix-2 DIT
- 共 6 個 stage
- 記憶體型架構（Memory-based implementation）
- 行為上等效 R2SDF

---

## 架構組成

- Complex RAM (64 entries)
- Twiddle ROM (Q8.8)
- Butterfly Core
- Address Generator
- FSM 控制流程

FSM 流程：

```
IDLE → LOAD → FFT → OUT → DONE
```

---

## 固定小數點設計

- Twiddle factor: Q8.8
- 乘法使用 32-bit 暫存
- 乘積右移 8 bits
- 控制量化誤差來源一致

---

## 驗證

- Verilog FFT output 與 C++ 完全一致
- 演算法順序與 twiddle index 對齊


---

# 三、Demapper 設計

## QPSK Demapper

- 依 Re / Im 正負判斷象限
- 2 bits / symbol
- 與 C++ 結果完全一致

---

## 16QAM Demapper

- 設定 threshold T2
- 四層 decision boundary
- 4 bits / symbol
- 與 C++ 結果一致


---

# 四、合成與 PPA 分析

## QPSK 版本

- Total Area：1,391,364.93
- Timing：MET
- Leakage Power：4.644 mW
- Clock Speed：20 MHz
- Throughput：10 Mbps

---

## 16QAM 版本

- Total Area：1,395,981.67
- Timing：MET
- Leakage Power：4.6378 mW
- Clock Speed：10 MHz
- Throughput：40 Mbps

---

## 分析重點

- 兩者前端架構完全共用
- 面積差異主要來自 Demapper 複雜度
- FFT 為主要面積來源
- Sequential Autocorrelation 有效控制硬體成本
- Fixed-point Q8.8 在效能與面積間取得平衡


---

# 設計特色

✔ CP-based synchronization FSM 架構  
✔ Multi-cycle divider 控制  
✔ Memory-based FFT 設計  
✔ Twiddle Q8.8 量化控制  
✔ RTL 與 C++ bit-level 對照驗證  
✔ Modulation-independent 前端共用設計  
✔ PPA 分析能力  

---

# 專案目錄結構

```
dcic_hw4/
├── spec/
├── exercise/
│   ├── rtl/
│   │   ├── common/
│   │   ├── qpsk/
│   │   └── 16qam/
│   ├── tb/
│   └── result/
├── .gitignore
└── README.md
```

---

## 作者

彭冠傑  
National Tsing Hua University  
Digital Communication IC Design