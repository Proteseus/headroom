const COMMUNITY_PAGE = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Headroom · Community Pulse</title>
  <style>
    :root { color-scheme: dark; --ink: #f5f0e8; --muted: #aaa49b; --line: #3a3835; --panel: #1b1a19; --accent: #d97757; --green: #73b88a; --blue: #7fa8d8; }
    * { box-sizing: border-box; }
    body { margin: 0; min-width: 320px; color: var(--ink); background: radial-gradient(circle at 10% 0%, #34251f, transparent 40rem), #11100f; font: 15px/1.5 ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    main { width: min(1080px, calc(100% - 40px)); margin: 0 auto; padding: 58px 0 70px; }
    a { color: var(--ink); text-underline-offset: 3px; }
    .eyebrow { color: var(--accent); font-size: 11px; font-weight: 800; letter-spacing: .16em; text-transform: uppercase; }
    h1 { max-width: 700px; margin: 10px 0 12px; font-size: clamp(38px, 7vw, 76px); line-height: .98; letter-spacing: -.06em; }
    .lede { max-width: 640px; margin: 0; color: var(--muted); font-size: 18px; }
    .meta { margin-top: 18px; color: var(--muted); font-size: 12px; }
    .grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin-top: 42px; }
    .panel { border: 1px solid var(--line); border-radius: 16px; background: color-mix(in srgb, var(--panel) 86%, transparent); padding: 20px; }
    .stat { min-height: 132px; }
    .label { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: .08em; }
    .value { margin-top: 12px; font-size: 32px; font-weight: 750; letter-spacing: -.04em; }
    .sub { margin-top: 3px; color: var(--muted); font-size: 12px; }
    .wide { grid-column: span 2; }
    .section-title { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; margin: 0 0 16px; font-size: 18px; letter-spacing: -.02em; }
    .section-title small { color: var(--muted); font-size: 12px; font-weight: 400; }
    .bars { display: flex; align-items: end; gap: 8px; height: 152px; padding-top: 12px; }
    .bar-wrap { display: flex; flex: 1; min-width: 0; height: 100%; align-items: end; gap: 5px; flex-direction: column; justify-content: end; }
    .bar { width: 100%; min-height: 4px; border-radius: 7px 7px 2px 2px; background: linear-gradient(180deg, var(--accent), #8f4c3a); }
    .bar-empty { background: #3b3936; }
    .bar-label { color: var(--muted); font-size: 10px; white-space: nowrap; }
    .rows { display: grid; gap: 12px; }
    .row { display: grid; grid-template-columns: 130px 1fr 42px; align-items: center; gap: 12px; }
    .row-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .track { height: 8px; overflow: hidden; border-radius: 99px; background: #373532; }
    .fill { height: 100%; border-radius: inherit; background: var(--blue); }
    .number { color: var(--muted); font-variant-numeric: tabular-nums; text-align: right; }
    .chips { display: flex; flex-wrap: wrap; gap: 8px; }
    .chip { border: 1px solid var(--line); border-radius: 99px; padding: 7px 10px; color: var(--muted); font-size: 12px; }
    .chip strong { color: var(--ink); }
    .empty { color: var(--muted); }
    footer { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 16px; margin-top: 34px; padding-top: 18px; border-top: 1px solid var(--line); color: var(--muted); font-size: 12px; }
    @media (max-width: 760px) { main { width: min(100% - 28px, 600px); padding-top: 36px; } .grid { grid-template-columns: repeat(2, 1fr); } .wide { grid-column: span 2; } .row { grid-template-columns: 100px 1fr 36px; } }
    @media (max-width: 420px) { .grid { display: block; } .panel { margin-top: 12px; } .stat { min-height: 112px; } }
  </style>
</head>
<body>
  <main>
    <div class="eyebrow">Headroom · anonymous · open</div>
    <h1>Community Pulse</h1>
    <p class="lede">A living snapshot of how the Headroom community builds, watches, and works with AI. Small groups stay invisible by design.</p>
    <div class="meta" id="meta">Loading the latest community snapshot…</div>

    <section class="grid" id="stats"></section>

    <section class="grid">
      <div class="panel wide"><h2 class="section-title">Weekly active Macs <small>reporting once per week</small></h2><div class="bars" id="weekly"></div></div>
      <div class="panel"><h2 class="section-title">Builds <small>latest week</small></h2><div class="rows" id="versions"></div></div>
      <div class="panel"><h2 class="section-title">Services in use <small>latest week</small></h2><div class="rows" id="services"></div></div>
      <div class="panel wide"><h2 class="section-title">Model family mix <small>average share</small></h2><div class="rows" id="models"></div></div>
      <div class="panel"><h2 class="section-title">Community features</h2><div class="chips" id="features"></div></div>
    </section>

    <footer>
      <span>Aggregates are public. Raw batches, IP addresses, identities, prompts, and model names are not.</span>
      <span><a href="https://github.com/michellzappa/headroom">Source</a> · <a href="https://github.com/michellzappa/headroom/blob/main/docs/telemetry.md">Privacy contract</a></span>
    </footer>
  </main>
  <script>
    const esc = (value) => String(value ?? '').replace(/[&<>\"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '\"': '&quot;', "'": '&#39;' }[char]));
    const title = (value) => String(value).replace(/[-_]/g, ' ').replace(/\\b\\w/g, (char) => char.toUpperCase());
    const number = (value) => value == null ? 'Growing' : value.toLocaleString();
    const empty = (message) => '<div class="empty">' + esc(message) + '</div>';
    const rows = (items, total, suffix) => items.length ? items.map((item) => {
      const percent = total ? Math.round(item.count / total * 100) : 0;
      return '<div class="row"><span class="row-name" title="' + esc(item.name) + '">' + esc(title(item.name)) + '</span><span class="track"><span class="fill" style="width:' + percent + '%"></span></span><span class="number">' + esc(item.count) + (suffix || '') + '</span></div>';
    }).join('') : empty('Not enough community data to publish this yet.');
    const modelRows = (items) => items.length ? items.map((item) => {
      const parts = item.name.split(':');
      const name = parts.length > 1 ? title(parts[1]) : title(item.name);
      return '<div class="row"><span class="row-name" title="' + esc(item.name) + '">' + esc(name) + '</span><span class="track"><span class="fill" style="width:' + item.share + '%;background:var(--accent)"></span></span><span class="number">' + esc(item.share) + '%</span></div>';
    }).join('') : empty('Not enough community data to publish this yet.');
    function render(data) {
      const latest = data.latest;
      document.querySelector('#meta').textContent = latest ? 'Latest snapshot: ' + latest.period + ' · published ' + data.generated_on + ' · groups smaller than ' + data.privacy.minimum_group_size + ' are withheld' : 'The pulse starts when at least ' + data.privacy.minimum_group_size + ' Macs contribute.';
      if (!latest) {
        document.querySelector('#stats').innerHTML = '<div class="panel stat"><div class="label">Community status</div><div class="value">Growing</div><div class="sub">Waiting for the first privacy threshold</div></div>';
        ['weekly', 'versions', 'services', 'models', 'features'].forEach((id) => document.querySelector('#' + id).innerHTML = empty('Not enough community data to publish this yet.'));
        return;
      }
      const used = latest.services.used || [];
      document.querySelector('#stats').innerHTML = '<div class="panel stat"><div class="label">Weekly active Macs</div><div class="value">' + number(latest.reporting_macs) + '</div><div class="sub">' + esc(latest.period) + '</div></div>' +
        '<div class="panel stat"><div class="label">Most common build</div><div class="value">' + esc(latest.versions[0]?.name || '—') + '</div><div class="sub">' + (latest.versions[0] ? esc(latest.versions[0].count) + ' reporting Macs' : 'Not published yet') + '</div></div>' +
        '<div class="panel stat"><div class="label">Services in use</div><div class="value">' + esc(used.length) + '</div><div class="sub">Across the latest week</div></div>' +
        '<div class="panel stat"><div class="label">Pulse status</div><div class="value">Open</div><div class="sub">Community-owned aggregates</div></div>';
      const weekly = data.weekly_active_macs || [];
      const max = Math.max(1, ...weekly.map((item) => item.count || 0));
      document.querySelector('#weekly').innerHTML = weekly.length ? weekly.map((item) => '<div class="bar-wrap"><div class="bar ' + (item.count == null ? 'bar-empty' : '') + '" style="height:' + Math.max(4, ((item.count || 0) / max) * 112) + 'px" title="' + esc(item.period) + '"></div><div class="bar-label">' + esc(item.period.slice(6)) + '</div></div>').join('') : empty('Not enough community data yet.');
      document.querySelector('#versions').innerHTML = rows(latest.versions || [], latest.reporting_macs, '');
      document.querySelector('#services').innerHTML = rows(used, latest.reporting_macs, '');
      document.querySelector('#models').innerHTML = modelRows(latest.model_shares || []);
      document.querySelector('#features').innerHTML = latest.features?.length ? latest.features.map((item) => '<span class="chip">' + esc(title(item.name)) + ' <strong>' + esc(item.adoption) + '%</strong></span>').join('') : empty('Not enough community data to publish this yet.');
    }
    fetch('/v1/community').then((response) => response.json()).then(render).catch(() => { document.querySelector('#meta').textContent = 'The community snapshot is temporarily unavailable.'; });
  </script>
</body>
</html>`;

export function communityPage() {
  return COMMUNITY_PAGE;
}
