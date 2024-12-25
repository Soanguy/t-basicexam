## 介紹

一個簡單地試卷生成模塊，專用於 ConTeXt。目前具有的功能有：

- 選擇題
- 填空題
- 材料題
- 問答題
- 完形填空題
- 答案控制
- 分數控制
- 題頭控制

## 預覽

參見 `MANUAL and EXAMPLE` 文件夾下具體文件。

![](./MANUAL%20and%20EXAMPLE/assets/soanguy-103113.png)

![](./MANUAL%20and%20EXAMPLE/assets/soanguy-1048579.png)

![](./MANUAL%20and%20EXAMPLE/assets/soanguy-105577.png)

![](./MANUAL%20and%20EXAMPLE/assets/soanguy-1020859.png)

## 安裝

下載後，放置在 context 安裝路徑下（context-osx-arm64/tex/texmf-local/tex/context/third/）。

在終端中使用：`mtxrun --generate` 刷新文件索引。

在文件中使用 `\usemodule[basicexam]` 即可使用。

## 示例

```
\definepapertitle[list={key},key=value]
\setuppapertitle[keycolor=red]
```

```
\startquestion
  \startchoice
    \startcitem   choice 1 \stopcitem
    \startcitem[*]choice 2 \stopcitem
    \startcitem   choice 3 \stopcitem
    \startcitem   choice 4 \stopcitem
  \stopchoice
\stopquestion

--->
\startquestion
  \fastchoice{choice 1,\correct{choice 2},{[*]choice 3},choice 4}
\stopquestion
```

```
\startquestion
  \startproblem
    \startpitem[answer=answer 1] problem 1 \stoppitem
    \startpitem[answer=answer 2] problem 1 \stoppitem
    \startpitem[answer=answer 3] problem 1 \stoppitem
  \stopproblem
\stopquestion
```

```
\startmaterial[title={Knuth},author={Mos},source={Yelu}]
   some text here \indicator{underline text}
\stopmaterial
```

> 增加了在終端中的信息輸出，包括題號， 答案， 分值， 等內容。（`\usemodule[mode=check]` 即可啟用。）

## TODO

- 當前儘可以記錄題號，但無法記錄節號。（將當前章節號一併記錄到 data 中，並佔位一個 unique）
- 記錄當前題目、題幹和題項。（是否有必要記錄。使用 data 記錄是否過於複雜？）
- 答案輸出，以上兩項都在為此項服務。除此之外，控制答案輸出的樣式。同時，提供便利命令快速獲取對應題號答案。
- 目前設置 citem 和 pitem 需要套嵌多層環境，需要調整環境的層級，可以快捷設置。（通過 processcommalist 可以設置）(已處理 citem => fastchoice)
- 目前沒有為數學環境優化。
- 目前答案環境設置了 參考答案 和 答案區域（用於學生書寫答案），但比較簡單。或許有更多的參數需要設置。
- 目錄設置：目前目錄相關的設置幾乎沒有。僅能夠生成試卷題頭，需要增加設置可以自行生成目錄。（writetolist 無法設置數字，需要其他命令）這一部分或許需要更改 definepapertitle 命令，混合 definehead 命令才更可靠。
- 目前的手冊說明比較單薄。純粹依靠編寫時的註釋和部分例子說明。（雖然之前有過手冊，現在已經完全併入代碼之中。）
- 連線題？
- 作文格？
- 上面兩個涉及到未知領域 metapost。
- 可以增加一些標記性命令，隨行文標記答案解釋，但不進入答案彙總。
- 目前對於答案和分值的顯示不是很明晰，每種題型一顯並顯，一隱俱藏。這不符合題目的具體要求，需要進行調整分值和答案的具體顯示條件。
