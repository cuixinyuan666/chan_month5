缠论 K 线（chan_kline）发布包

怎么用
1. 解压整个文件夹，不要只拷贝其中一个 exe。
2. 推荐双击「启动 chan_kline.bat」启动（会自动加载同目录 a_Data）。
   若直接双击 chan_kline.exe，需手动设环境变量 CHAN_DATA_ROOT 指向解压目录下的 a_Data。
3. 行情数据在同目录 a_Data（默认股票 002003）。也可设环境变量 CHAN_DATA_ROOT 指向别的数据目录。

注意
- chan_ffi.dll 必须和 chan_kline.exe 在同一目录，单独拖走 exe 会打不开。
- a_Data 文件夹必须和 exe 在同一层，解压后不要删掉。
- Windows 若提示缺少运行库：安装 Microsoft Visual C++ Redistributable（x64）。
