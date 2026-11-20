// テストプレイ部のモデル解析キット（three.js 0.187 をまとめて assets/vendor/model-kit.js に書き出す）
//   作り方：bash scripts/build_model_kit.sh
//   使い方：
//     const kit = await TPBModel.load(arrayBuffer)            … .glb / .vrm を読む
//     kit.stats                                               … ポリゴン数・テクスチャ・UV・ボーン・表情・アニメ・大きさなどの数字
//     await kit.shots()                                       … 正面・横・後ろ・斜め上・ワイヤー（＋骨）の画像（JPEG の dataURL）
//     kit.mount(element)                                      … ぐるぐる回して見られる画面を置く。kit.setMode('normal'|'wire'|'bones')
//     kit.dispose()
import * as THREE from "three";
import { GLTFLoader } from "three/examples/jsm/loaders/GLTFLoader.js";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
import { RoomEnvironment } from "three/examples/jsm/environments/RoomEnvironment.js";

const DEFAULT_NAME = /^(cube|sphere|cylinder|plane|cone|torus|mesh|object|empty|icosphere|circle|pcube|psphere|pcylinder|pplane|polysurface|group|null)[._ ]?\d*$/i;
const HUMANOID = {
  hips: /hips?|pelvis/i, spine: /spine/i, chest: /chest|spine[._ ]?0?[2-9]/i, neck: /neck/i, head: /head(?!.*(top|end))/i,
  upper_arm: /upper[._ ]?arm|arm[._ ]?(upper|l|r)?$|shoulder/i, lower_arm: /fore[._ ]?arm|lower[._ ]?arm|elbow/i, hand: /hand(?!.*(thumb|index|middle|ring|little|pinky))/i,
  upper_leg: /up[._ ]?leg|thigh|upper[._ ]?leg/i, lower_leg: /calf|shin|knee|lower[._ ]?leg|^(.*[._ ])?leg[._ ]?(l|r)?$/i, foot: /foot|ankle/i,
  fingers: /thumb|index|middle|ring|little|pinky|finger/i, eyes: /eye/i, jaw: /jaw/i,
};
const FACE = /blink|eye|brow|mouth|vrc\.|^v_|viseme|smile|angry|sad|joy|fun|sorrow|surprise|^[aiueo]$|^(あ|い|う|え|お|まばたき|笑い|ウィンク)/i;

function isPOT(n) { return n > 0 && (n & (n - 1)) === 0 }
function r1(n) { return Math.round(n * 10) / 10 }
function r3(n) { return Math.round(n * 1000) / 1000 }

function analyze(gltf, fileBytes) {
  const json = gltf.parser && gltf.parser.json || {};
  const scene = gltf.scene;
  scene.updateMatrixWorld(true);
  let tris = 0, verts = 0, meshes = 0, skinned = 0, prims = 0, noUv = 0, uv2 = 0, noNormal = 0, tangents = 0, vcol = 0, degenerate = 0, sampled = 0, nodes = 0, defaultNames = 0;
  const heavy = [], mats = new Map(), texs = new Map(), bones = new Set(), morph = new Set(), lods = [], defaultList = [];
  const a = new THREE.Vector3(), b = new THREE.Vector3(), c = new THREE.Vector3(), ab = new THREE.Vector3(), ac = new THREE.Vector3();
  scene.traverse((o) => {
    nodes++;
    if (o.name && DEFAULT_NAME.test(o.name)) { defaultNames++; if (defaultList.length < 8) defaultList.push(o.name) }
    if (/_?lod[._ ]?\d/i.test(o.name || "")) lods.push(o.name);
    if (!o.isMesh) return;
    meshes++; if (o.isSkinnedMesh) skinned++;
    const g = o.geometry; const pos = g.attributes.position; if (!pos) return;
    const t = g.index ? g.index.count / 3 : pos.count / 3;
    tris += t; verts += pos.count; prims++;
    heavy.push({ name: o.name || "(名前なし)", tris: Math.round(t) });
    if (!g.attributes.uv) noUv++;
    if (g.attributes.uv1 || g.attributes.uv2) uv2++;
    if (!g.attributes.normal) noNormal++;
    if (g.attributes.tangent) tangents++;
    if (g.attributes.color) vcol++;
    if (o.morphTargetDictionary) Object.keys(o.morphTargetDictionary).forEach((k) => morph.add(k));
    if (o.isSkinnedMesh && o.skeleton) o.skeleton.bones.forEach((bn) => bones.add(bn.name || bn.uuid));
    // つぶれた三角形（面積0）：多くても30万枚まで数える
    if (sampled < 300000) {
      const idx = g.index; const n = Math.min(t, 300000 - sampled);
      for (let i = 0; i < n; i++) {
        const i0 = idx ? idx.getX(i * 3) : i * 3, i1 = idx ? idx.getX(i * 3 + 1) : i * 3 + 1, i2 = idx ? idx.getX(i * 3 + 2) : i * 3 + 2;
        a.fromBufferAttribute(pos, i0); b.fromBufferAttribute(pos, i1); c.fromBufferAttribute(pos, i2);
        if (ab.subVectors(b, a).cross(ac.subVectors(c, a)).lengthSq() < 1e-16) degenerate++;
      }
      sampled += n;
    }
    (Array.isArray(o.material) ? o.material : [o.material]).forEach((m) => {
      if (!m || mats.has(m.uuid)) return;
      const maps = {};
      ["map", "normalMap", "roughnessMap", "metalnessMap", "emissiveMap", "aoMap", "alphaMap"].forEach((k) => {
        const tx = m[k]; if (!tx) return; maps[k] = true;
        const img = tx.image; const w = img && (img.width || img.videoWidth) || 0, h = img && (img.height || img.videoHeight) || 0;
        if (!texs.has(tx.uuid)) texs.set(tx.uuid, { name: tx.name || (img && img.src ? "" : ""), w, h, use: k });
      });
      mats.set(m.uuid, { name: m.name || "(名前なし)", type: m.type.replace("Material", ""), maps: Object.keys(maps), transparent: !!m.transparent, alphaTest: m.alphaTest || 0, doubleSided: m.side === THREE.DoubleSide });
    });
  });
  heavy.sort((x, y) => y.tris - x.tris);
  const box = new THREE.Box3().setFromObject(scene); const size = box.getSize(new THREE.Vector3()); const center = box.getCenter(new THREE.Vector3());
  const tex = [...texs.values()];
  const gpuMB = tex.reduce((s, t) => s + t.w * t.h * 4 * 1.33, 0) / 1048576;
  const boneNames = [...bones];
  const found = {}; Object.entries(HUMANOID).forEach(([k, re]) => { found[k] = boneNames.some((n) => re.test(n)) });
  const morphNames = [...morph];
  const ext = [...new Set([...(json.extensionsUsed || []), ...Object.keys(json.extensions || {})])];
  return {
    file_mb: r1(fileBytes / 1048576),
    generator: String((json.asset && json.asset.generator) || "").slice(0, 80),
    extensions: ext.slice(0, 20),
    vrm: ext.some((e) => /^VRM/i.test(e)),
    triangles: Math.round(tris), vertices: verts, meshes, skinned_meshes: skinned, draw_calls_est: prims * 1,
    heaviest_meshes: heavy.slice(0, 5),
    nodes, default_named: defaultNames, default_named_examples: defaultList,
    lod_nodes: lods.slice(0, 8),
    materials: mats.size, material_list: [...mats.values()].slice(0, 12),
    textures: tex.length, texture_sizes: tex.map((t) => `${t.w}x${t.h}`).slice(0, 20),
    texture_max: tex.reduce((m, t) => Math.max(m, t.w, t.h), 0),
    texture_non_pot: tex.filter((t) => t.w && (!isPOT(t.w) || !isPOT(t.h))).length,
    texture_gpu_mb_est: r1(gpuMB),
    has_normal_map: [...mats.values()].some((m) => m.maps.includes("normalMap")),
    primitives_without_uv: noUv, primitives_with_uv2: uv2, primitives_without_normals: noNormal, primitives_with_tangents: tangents, primitives_with_vertex_colors: vcol,
    degenerate_triangles: degenerate, degenerate_checked: sampled,
    bones: boneNames.length, bone_examples: boneNames.slice(0, 60), humanoid_parts: found,
    morph_targets: morphNames.length, morph_examples: morphNames.slice(0, 40), face_like_morphs: morphNames.filter((n) => FACE.test(n)).length,
    animations: (gltf.animations || []).map((an) => ({ name: an.name || "(名前なし)", seconds: r1(an.duration), tracks: an.tracks.length })).slice(0, 20),
    size_m: { x: r3(size.x), y: r3(size.y), z: r3(size.z) },
    min_y: r3(box.min.y), center_offset_xz: r3(Math.hypot(center.x, center.z)),
  };
}

function makeRenderer(w, h, keep) {
  const r = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: !!keep, alpha: false });
  r.setPixelRatio(1); r.setSize(w, h, false); r.outputColorSpace = THREE.SRGBColorSpace; r.toneMapping = THREE.ACESFilmicToneMapping;
  return r;
}

function frame(camera, box, dir) {
  const size = box.getSize(new THREE.Vector3()), center = box.getCenter(new THREE.Vector3());
  const radius = Math.max(size.length() / 2, 1e-3);
  let dist = radius / Math.sin((camera.fov * Math.PI / 180) / 2) * 1.05;
  const d = dir.clone().normalize(), corners = [];
  for (let i = 0; i < 8; i++) corners.push(new THREE.Vector3(i & 1 ? box.max.x : box.min.x, i & 2 ? box.max.y : box.min.y, i & 4 ? box.max.z : box.min.z));
  // 見る向きから見た大きさに合わせて、画面の9割に収まるよう近づける（2回くり返す）
  for (let k = 0; k < 3; k++) {
    camera.position.copy(center).addScaledVector(d, dist);
    camera.near = dist / 100; camera.far = dist * 100; camera.updateProjectionMatrix(); camera.lookAt(center); camera.updateMatrixWorld(true);
    let m = 0; for (const c of corners) { const p = c.clone().project(camera); m = Math.max(m, Math.abs(p.x), Math.abs(p.y)) }
    if (!isFinite(m) || m <= 0) break;
    dist *= m / 0.88;
  }
  camera.position.copy(center).addScaledVector(d, dist);
  camera.near = dist / 100; camera.far = dist * 100; camera.updateProjectionMatrix(); camera.lookAt(center);
  return center;
}

class Kit {
  constructor(gltf, bytes) {
    this.gltf = gltf; this.root = gltf.scene; this.stats = analyze(gltf, bytes);
    this.scene = new THREE.Scene(); this.scene.background = new THREE.Color(0xeeeae2);
    this.scene.add(this.root);
    this.scene.add(new THREE.HemisphereLight(0xffffff, 0x8a8278, 1.2));
    const d = new THREE.DirectionalLight(0xffffff, 1.6); d.position.set(2, 4, 3); this.scene.add(d);
    this.box = new THREE.Box3().setFromObject(this.root);
    this.skel = null;
    this.root.traverse((o) => { if (o.isSkinnedMesh && !this.skel) { this.skel = new THREE.SkeletonHelper(this.root); this.skel.visible = false; this.scene.add(this.skel) } });
    this.camera = new THREE.PerspectiveCamera(35, 1, 0.01, 1000);
    this.mode = "normal"; this._orig = new Map();
  }
  _env(renderer) {
    if (this._envFor === renderer) return;
    const pm = new THREE.PMREMGenerator(renderer); this.scene.environment = pm.fromScene(new RoomEnvironment(), 0.04).texture; pm.dispose(); this._envFor = renderer;
  }
  setMode(m) {
    this.mode = m;
    const wire = m === "wire";
    this.root.traverse((o) => {
      if (!o.isMesh) return;
      if (wire) {
        if (!this._orig.has(o)) this._orig.set(o, o.material);
        o.material = new THREE.MeshBasicMaterial({ color: 0x2a241e, wireframe: true });
      } else if (this._orig.has(o)) { o.material.dispose(); o.material = this._orig.get(o); this._orig.delete(o) }
      if (m === "bones") { (Array.isArray(o.material) ? o.material : [o.material]).forEach((mt) => { mt.transparent = true; mt.opacity = 0.35; mt.needsUpdate = true }) }
      else if (!wire) { (Array.isArray(o.material) ? o.material : [o.material]).forEach((mt) => { if (mt.userData.__op == null) mt.userData.__op = mt.opacity; mt.opacity = mt.userData.__op; mt.transparent = mt.userData.__tr ?? mt.transparent; mt.needsUpdate = true }) }
    });
    if (this.skel) this.skel.visible = m === "bones";
    if (this._render) this._render();
  }
  async shots(size = 512) {
    const r = makeRenderer(size, size, true); this._env(r);
    this.camera.aspect = 1;
    const out = [];
    const views = [["正面", new THREE.Vector3(0, 0.15, 1), "normal"], ["右横", new THREE.Vector3(1, 0.15, 0), "normal"], ["後ろ", new THREE.Vector3(0, 0.15, -1), "normal"],
                   ["斜め上", new THREE.Vector3(0.8, 0.9, 0.9), "normal"], ["ワイヤー（正面）", new THREE.Vector3(0, 0.15, 1), "wire"]];
    if (this.skel) views.push(["骨（正面）", new THREE.Vector3(0, 0.15, 1), "bones"]);
    const prev = this.mode;
    for (const [label, dir, mode] of views) {
      this.setMode(mode); frame(this.camera, this.box, dir); r.render(this.scene, this.camera);
      out.push({ label, data: r.domElement.toDataURL("image/jpeg", 0.82) });
      await new Promise((res) => setTimeout(res, 0));
    }
    this.setMode(prev); r.dispose(); if (this._envFor === r) this._envFor = null;
    return out;
  }
  mount(el) {
    const w = el.clientWidth || 480, h = el.clientHeight || 360;
    const r = this._viewR = makeRenderer(w, h, false); this._env(r); r.domElement.style.cssText = "width:100%;height:100%;display:block;touch-action:none";
    el.replaceChildren(r.domElement);
    this.camera.aspect = w / h; frame(this.camera, this.box, new THREE.Vector3(0.6, 0.3, 1));
    const ctl = this._ctl = new OrbitControls(this.camera, r.domElement); ctl.target.copy(this.box.getCenter(new THREE.Vector3())); ctl.update();
    this._render = () => r.render(this.scene, this.camera);
    ctl.addEventListener("change", this._render); this._render();
    this._ro = new ResizeObserver(() => { const W = el.clientWidth, H = el.clientHeight; if (!W || !H) return; r.setSize(W, H, false); this.camera.aspect = W / H; this.camera.updateProjectionMatrix(); this._render() });
    this._ro.observe(el);
  }
  dispose() {
    if (this._ro) this._ro.disconnect(); if (this._ctl) this._ctl.dispose(); if (this._viewR) { this._viewR.dispose(); this._viewR.domElement.remove() }
    this.scene.traverse((o) => { if (o.geometry) o.geometry.dispose(); const m = o.material; (Array.isArray(m) ? m : m ? [m] : []).forEach((mt) => { Object.values(mt).forEach((v) => { if (v && v.isTexture) v.dispose() }); mt.dispose() }) });
  }
}

async function load(buf) {
  const bytes = buf.byteLength;
  // 先に中身の決まり（extensionsRequired）を見て、読めない圧縮は分かる言葉で返す
  try {
    const dv = new DataView(buf); if (dv.getUint32(0, true) === 0x46546c67) {
      const len = dv.getUint32(12, true); const j = JSON.parse(new TextDecoder().decode(new Uint8Array(buf, 20, len)));
      const req = j.extensionsRequired || [];
      if (req.includes("KHR_draco_mesh_compression") || req.includes("EXT_meshopt_compression")) throw new Error("compressed");
      if (req.includes("KHR_texture_basisu")) throw new Error("ktx2");
    } else throw new Error("not_glb");
  } catch (e) { if (["compressed", "ktx2", "not_glb"].includes(e.message)) throw e }
  const gltf = await new GLTFLoader().parseAsync(buf, "");
  return new Kit(gltf, bytes);
}

window.TPBModel = { load, version: THREE.REVISION };
