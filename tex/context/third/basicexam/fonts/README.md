# 打字集

## CJK 打字集

| 打字集 | 中文             | 繁中              | 日文             |
| ------ | ---------------- | ----------------- | ---------------- |
| adobe  | adobehans        | adobehant         | kozuka           |
| source | sourcehancn      | sourcehank        | sourcehanja      |
|        | sourcehancnlight | sourcehanklight   | sourcehanjalight |
|        |                  | genyotw/genyotc   |                  |
|        |                  | genryutw/genryutc |                  |
| macos  | sinohans         | sinohant          | jiyou            |
|        |                  | lihant            |                  |
|        |                  |                   | hiragino         |
| others |                  |                   |                  |

others 打字集待處理，需要進行整合。

## 英文打字集

英文打字集作為回退字體替換 CJK 打字集，無法直接作為可以使用的字體。

| 打字集     |                | 備註          |
| ---------- | -------------- | ------------- |
| cormorant  | cormorantlight |               |
| ibmplex    |                |               |
| libertinum |                | libertinus    |
| texgyre    |                | times + heros |
| gentium    |                |               |
| ubuntu     |                |               |



\definefontfeature[maple][default]
                  [mode=node,liga=yes,language=dflt,script=latn,
                   cv01=false,%@ \# \$ \% \& Q -> =>
                   cv02=false,%i
                   cv03=true, %a
                   cv04=false,%@
                   ss01=yes, %== === ！= ！==
                   ss02=yes, %[info][trace][debug][warn][error][fatall][vite]
                   ss03=yes, %--
                   ss04=yes, % >= <=
                   ss05=yes, %{{}}
                   ]