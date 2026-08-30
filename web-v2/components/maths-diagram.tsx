type DiagramPayload = Record<string, unknown>;
type Point = [number, number];

const line = (a: Point, b: Point, key: string, dashed = false) =>
  <line key={key} x1={a[0]} y1={a[1]} x2={b[0]} y2={b[1]} className={dashed ? "dash" : "shape"} />;
const point = (p: Point, label: string, key: string) => <g key={key}><circle cx={p[0]} cy={p[1]} r="3" className="pt" /><text x={p[0] + 9} y={p[1] - 7}>{label}</text></g>;

function metadata(payload: DiagramPayload) {
  const values: string[] = [];
  const add = (label: string, value: unknown) => {
    if ((typeof value === "string" || typeof value === "number") && String(value).length < 80) values.push(`${label}=${value}`);
  };
  Object.entries(payload).slice(0, 12).forEach(([key, value]) => {
    if (Array.isArray(value)) value.slice(0, 3).forEach((item, index) => add(`${key} ${index + 1}`, item));
    else if (value && typeof value === "object") Object.entries(value as DiagramPayload).slice(0, 3).forEach(([child, item]) => add(`${key} ${child}`, item));
    else add(key, value);
  });
  return [...new Set(values)].slice(0, 8).join(" · ");
}

function Triangle({ type }: { type: string }) {
  const right = type.includes("right") || type.includes("height");
  const a: Point = right ? [65, 180] : [180, 28];
  const b: Point = right ? [300, 180] : [55, 185];
  const c: Point = right ? [65, 45] : [305, 185];
  const mid: Point = [(b[0] + c[0]) / 2, (b[1] + c[1]) / 2];
  return <>{line(a, b, "ab")}{line(b, c, "bc")}{line(c, a, "ca")}{point(a, "A", "a")}{point(b, "B", "b")}{point(c, "C", "c")}
    {right && <path className="thin" d={`M ${a[0]} ${a[1] - 13} h 13 v 13`} />}
    {/median|centroid|height|bisector|midpoint/.test(type) && line(a, mid, "median", true)}
    {type.includes("centroid") && point([(a[0] + b[0] + c[0]) / 3, (a[1] + b[1] + c[1]) / 3], "G", "g")}
    {/circum|incenter/.test(type) && <circle cx="180" cy="112" r={type.includes("incenter") ? 34 : 88} className="thin" />}
  </>;
}

function Circle({ type }: { type: string }) {
  return <><circle cx="180" cy="110" r="80" className="shape" />{point([180, 110], "O", "o")}
    {type.includes("tangent") && <>{line([260, 25], [260, 195], "tangent")}{line([180, 110], [260, 110], "radius", true)}</>}
    {type.includes("chord") && line([120, 62], [240, 62], "chord")}
    {type.includes("secant") && line([72, 170], [325, 42], "secant")}
    {type.includes("sector") && <>{line([180, 110], [260, 110], "sector-a")}{line([180, 110], [220, 42], "sector-b")}</>}
    {type.includes("cyclic") && <polygon points="130,45 240,55 255,150 105,160" className="thin" />}
    {type.includes("semicircle") && line([100, 110], [260, 110], "diameter")}
  </>;
}

function Coordinate({ type }: { type: string }) {
  return <>{line([25, 110], [335, 110], "x")}{line([180, 205], [180, 18], "y")}<text x="338" y="105">x</text><text x="188" y="22">y</text>{point([180, 110], "O", "o")}
    {type.includes("triangle") ? <polygon points="95,165 270,165 135,45" className="shape" /> : <>{line([60, 170], [300, 50], "plot")}{point([115, 143], "P", "p")}</>}
    {type.includes("reflection") && line([72, 180], [286, 38], "mirror", true)}
    {type.includes("distance") && <>{line([95, 155], [270, 155], "dx", true)}{line([270, 155], [270, 55], "dy", true)}</>}
  </>;
}

function Solid({ type }: { type: string }) {
  if (type.includes("sphere")) return <><circle cx="180" cy="110" r="72" className="shape" /><ellipse cx="180" cy="110" rx="72" ry="22" className="thin" /></>;
  if (type.includes("cylinder")) return <><ellipse cx="180" cy="48" rx="70" ry="23" className="shape" /><ellipse cx="180" cy="171" rx="70" ry="23" className="shape" />{line([110, 48], [110, 171], "left")}{line([250, 48], [250, 171], "right")}</>;
  if (/cone|frustum/.test(type)) return <><ellipse cx="180" cy="172" rx="82" ry="25" className="shape" />{line([180, 28], [98, 172], "left")}{line([180, 28], [262, 172], "right")}{line([180, 28], [180, 172], "height", true)}</>;
  return <><rect x="80" y="68" width="155" height="108" className="shape" /><rect x="125" y="35" width="155" height="108" className="thin" />{line([80, 68], [125, 35], "a")}{line([235, 68], [280, 35], "b")}{line([235, 176], [280, 143], "c")}</>;
}

function Quadrilateral({ type }: { type: string }) {
  const points = type.includes("trapezium") ? "85,55 270,55 320,175 45,175" : type.includes("rhombus") ? "180,30 300,110 180,190 60,110" : "70,48 290,48 290,178 70,178";
  return <><polygon points={points} className="shape" />{/diagonal|rhombus|square|rectangle/.test(type) && <>{line([70, 48], [290, 178], "d1", true)}{line([290, 48], [70, 178], "d2", true)}</>}</>;
}

function Lines({ type }: { type: string }) {
  if (/parallel|transversal/.test(type)) return <>{line([40, 62], [320, 62], "a")}{line([40, 158], [320, 158], "b")}{line([120, 20], [238, 205], "t")}</>;
  if (/perpendicular/.test(type)) return <>{line([35, 110], [325, 110], "h")}{line([180, 25], [180, 195], "v")}<path className="thin" d="M 180 97 h 13 v 13" /></>;
  return <>{line([65, 175], [310, 175], "a")}{line([65, 175], [255, 42], "b")}{type.includes("bisector") && line([65, 175], [285, 105], "bisector", true)}{point([65, 175], "O", "o")}</>;
}

export function MathsDiagram({ diagram }: { diagram: { type?: string; payload: unknown } }) {
  if (!diagram.payload || Array.isArray(diagram.payload) || typeof diagram.payload !== "object") return null;
  const payload = diagram.payload as DiagramPayload;
  if (!Object.keys(payload).length || payload.show === false) return null;
  const type = String(diagram.type || "structured_json_untyped").toLowerCase();
  let body = null;
  if (type.startsWith("coordinate_")) body = <Coordinate type={type} />;
  else if (/triangle|median|centroid|incenter|circumcenter|orthocenter|similar|congruent|bisector|midpoint|equilateral|isosceles/.test(type)) body = <Triangle type={type} />;
  else if (/circle|chord|tangent|secant|cyclic|semicircle|sector/.test(type)) body = <Circle type={type} />;
  else if (/cuboid|cube|box|cylinder|cone|frustum|sphere|hemisphere|solid|capsule|prism|pyramid|tetrahedron|recasting/.test(type)) body = <Solid type={type} />;
  else if (/trapezium|parallelogram|rectangle|rhombus|square|kite|quadrilateral|polygon|hexagon|path/.test(type)) body = <Quadrilateral type={type} />;
  else if (/line|angle|parallel|transversal|collinear|intersect|complement|supplement|perpendicular|coplanar|concurrent/.test(type)) body = <Lines type={type} />;
  const meta = metadata(payload);
  return <figure className="m-diagram" aria-label={`Mathematical diagram: ${type.replaceAll("_", " ")}`}>
    {body && <svg className="math-diagram" viewBox="0 0 360 220" role="img" aria-hidden="true">{body}</svg>}
    {meta && <figcaption>{meta}</figcaption>}
    {(payload.notToScale === true || String(payload.note || "").toLowerCase().includes("not drawn to scale")) && <small>Not drawn to scale</small>}
  </figure>;
}
