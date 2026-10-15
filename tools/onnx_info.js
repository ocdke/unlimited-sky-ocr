// 轻量 ONNX 元信息解析器 (只依赖 protobuf wire format, 无需任何第三方库)
// 用途: 读取模型的输入/输出张量名与形状, 验证类别数 / 通道数
//
// 用法: node tools/onnx_info.js <model.onnx> [...]
'use strict';
const fs = require('fs');
const path = require('path');

// ---------- 通用 protobuf 读取 ----------
function readVarint(buf, pos) {
  let result = 0n, shift = 0n, b;
  do {
    b = buf[pos++];
    result |= BigInt(b & 0x7f) << shift;
    shift += 7n;
  } while (b & 0x80);
  return [Number(result), pos];
}

function parseMessage(buf, start = 0, end = buf.length) {
  const fields = [];
  let pos = start;
  while (pos < end) {
    let key;
    [key, pos] = readVarint(buf, pos);
    const field = key >>> 3;
    const wire = key & 7;
    if (wire === 0) {
      let v;
      [v, pos] = readVarint(buf, pos);
      fields.push({ field, wire, value: v });
    } else if (wire === 1) {
      fields.push({ field, wire, value: buf.subarray(pos, pos + 8) });
      pos += 8;
    } else if (wire === 2) {
      let len;
      [len, pos] = readVarint(buf, pos);
      fields.push({ field, wire, value: buf.subarray(pos, pos + len) });
      pos += len;
    } else if (wire === 5) {
      fields.push({ field, wire, value: buf.subarray(pos, pos + 4) });
      pos += 4;
    } else {
      throw new Error(`不支持的 wire type ${wire} @${pos}`);
    }
  }
  return fields;
}

const get = (fields, f) => fields.filter((x) => x.field === f);
const getOne = (fields, f) => fields.find((x) => x.field === f);

function decodeStr(sub) {
  return sub.toString('utf8');
}

// ---------- ONNX 结构导航 ----------
const ELEM_TYPES = {
  1: 'float32', 2: 'uint8', 3: 'int8', 4: 'uint16', 5: 'int16', 6: 'int32',
  7: 'int64', 8: 'string', 9: 'bool', 10: 'float16', 11: 'float64',
  12: 'uint32', 13: 'uint64', 14: 'complex64', 15: 'complex128', 16: 'bfloat16',
};

function parseValueInfo(sub) {
  const f = parseMessage(sub);
  const nameF = getOne(f, 1);
  const name = nameF ? decodeStr(nameF.value) : '?';
  let dtype = '?';
  let shape = [];
  const typeF = getOne(f, 2);
  if (typeF) {
    const tf = parseMessage(typeF.value);
    const tensorF = getOne(tf, 1); // TypeProto.tensor_type
    if (tensorF) {
      const tt = parseMessage(tensorF.value);
      const et = getOne(tt, 1);
      if (et) dtype = ELEM_TYPES[et.value] || `#${et.value}`;
      const shapeF = getOne(tt, 2); // TensorShapeProto
      if (shapeF) {
        const sf = parseMessage(shapeF.value);
        for (const dim of get(sf, 1)) {
          const df = parseMessage(dim.value);
          const dv = getOne(df, 1);
          const dp = getOne(df, 2);
          if (dv) shape.push(dv.value);
          else if (dp) shape.push(decodeStr(dp.value));
          else shape.push('?');
        }
      }
    }
  }
  return { name, dtype, shape };
}

function parseOnnx(file) {
  const buf = fs.readFileSync(file);
  const model = parseMessage(buf);
  const graphF = getOne(model, 7); // ModelProto.graph
  if (!graphF) throw new Error('未找到 graph');
  const graph = parseMessage(graphF.value);
  const inputs = get(graph, 11).map((x) => parseValueInfo(x.value));
  const outputs = get(graph, 12).map((x) => parseValueInfo(x.value));
  const opsetF = get(model, 8); // opset_import
  const opsets = opsetF.map((o) => {
    const of = parseMessage(o.value);
    const v = getOne(of, 2);
    return v ? v.value : '?';
  });
  // 元信息 (RapidOCR 会把字典塞进 metadata_props)
  const metaF = get(model, 14); // ModelProto.metadata_props
  const meta = {};
  for (const m of metaF) {
    const mf = parseMessage(m.value);
    const k = getOne(mf, 1), v = getOne(mf, 2);
    if (k && v) meta[decodeStr(k.value)] = decodeStr(v.value);
  }
  return { inputs, outputs, opsets, meta, size: buf.length };
}

// ---------- 主流程 ----------
const files = process.argv.slice(2);
if (files.length === 0) {
  console.error('用法: node tools/onnx_info.js <model.onnx> [...]');
  process.exit(1);
}

for (const file of files) {
  try {
    const info = parseOnnx(file);
    console.log('='.repeat(78));
    console.log(path.basename(file), `  (${(info.size / 1048576).toFixed(2)} MB)`);
    console.log('  opset:', info.opsets.join(', '));
    for (const i of info.inputs) {
      console.log(`  INPUT  ${i.name.padEnd(24)} ${i.dtype.padEnd(9)} [${i.shape.join(', ')}]`);
    }
    for (const o of info.outputs) {
      console.log(`  OUTPUT ${o.name.padEnd(24)} ${o.dtype.padEnd(9)} [${o.shape.join(', ')}]`);
    }
    const keys = Object.keys(info.meta);
    if (keys.length) {
      console.log('  metadata:');
      for (const k of keys) {
        const v = info.meta[k];
        console.log(`    ${k} = ${v.length > 90 ? v.slice(0, 90) + `…(${v.length} 字符)` : v}`);
      }
    }
  } catch (e) {
    console.log('='.repeat(78));
    console.log(path.basename(file), '解析失败:', e.message);
  }
}
