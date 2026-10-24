// 打印 panel.config.json 里 key 的绝对路径，供 启动管理面板.cmd 做存在性检查。
// 单一事实来源：改了 panel.config.json 的 key，启动脚本自动跟着走，不用再改 .cmd。
const fs = require('node:fs');
const path = require('node:path');

const here = __dirname;
const cfgPath = path.join(here, 'panel.config.json');

if (!fs.existsSync(cfgPath)) {
  console.error(`[x] 找不到 ${cfgPath}`);
  process.exit(1);
}

let cfg;
try {
  cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
} catch (err) {
  console.error(`[x] panel.config.json 不是合法 JSON: ${err.message}`);
  process.exit(1);
}

if (!cfg.key) {
  console.error('[x] panel.config.json 里没有 key 字段');
  process.exit(1);
}

process.stdout.write(path.resolve(here, cfg.key));
