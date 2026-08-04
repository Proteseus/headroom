const COMMUNITY_PAGE = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Headroom · Community Pulse</title>
  <style>
    :root {
      color-scheme: light dark;
      --ink: #1c1c1c;
      --muted: #6b6b6b;
      --faint: #9a9a9a;
      --line: #d8d8d8;
      --panel: #ffffff;
      --page: #f3f3f3;
      --fill: #5c6b7a;
      --fill-soft: #a8b3bf;
      --track: #e6e6e6;
      --empty: #d0d0d0;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --ink: #ececec;
        --muted: #9a9a9a;
        --faint: #6e6e6e;
        --line: #333333;
        --panel: #1a1a1a;
        --page: #111111;
        --fill: #8a97a6;
        --fill-soft: #5a6570;
        --track: #2a2a2a;
        --empty: #3a3a3a;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-width: 320px;
      color: var(--ink);
      background: var(--page);
      font: 14px/1.45 ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    main { width: min(1100px, calc(100% - 40px)); margin: 0 auto; padding: 40px 0 56px; }
    a { color: var(--ink); text-underline-offset: 3px; }
    header { position: relative; margin-bottom: 28px; padding-right: 110px; }
    .kicker {
      margin: 0 0 8px;
      color: var(--muted);
      font-size: 11px;
      font-weight: 600;
      letter-spacing: .12em;
      text-transform: uppercase;
    }
    h1 { margin: 0 0 8px; font-size: 28px; font-weight: 650; letter-spacing: -.02em; }
    .lede { margin: 0; max-width: 62ch; color: var(--muted); }
    .meta { margin-top: 10px; color: var(--faint); font-size: 12px; }
    .stars {
      position: absolute;
      top: 0;
      right: 0;
      display: inline-flex;
      align-items: baseline;
      gap: 6px;
      border: 1px solid var(--line);
      border-radius: 4px;
      padding: 7px 10px;
      color: var(--ink);
      background: var(--panel);
      font-size: 12px;
      font-variant-numeric: tabular-nums;
      text-decoration: none;
      white-space: nowrap;
    }
    .stars:hover { border-color: var(--muted); }
    .stars .count { font-weight: 650; font-size: 14px; }
    .stars .label { color: var(--muted); }
    @media (max-width: 560px) {
      header { padding-right: 0; }
      .stars { position: static; margin: 0 0 14px; }
    }
    .stats {
      display: grid;
      grid-template-columns: repeat(4, 1fr);
      gap: 10px;
      margin: 0 0 12px;
    }
    .panel {
      border: 1px solid var(--line);
      border-radius: 4px;
      background: var(--panel);
      padding: 16px;
    }
    .stat .label {
      color: var(--muted);
      font-size: 11px;
      letter-spacing: .06em;
      text-transform: uppercase;
    }
    .stat .value {
      margin-top: 8px;
      font-size: 28px;
      font-weight: 650;
      font-variant-numeric: tabular-nums;
      letter-spacing: -.03em;
    }
    .stat .sub { margin-top: 2px; color: var(--muted); font-size: 12px; }
    .grid {
      display: grid;
      grid-template-columns: 1.4fr 1fr 1fr;
      gap: 10px;
    }
    .span-2 { grid-column: span 2; }
    .span-3 { grid-column: span 3; }
    .section-title {
      display: flex;
      align-items: baseline;
      justify-content: space-between;
      gap: 12px;
      margin: 0 0 14px;
      font-size: 13px;
      font-weight: 650;
    }
    .section-title small { color: var(--muted); font-size: 11px; font-weight: 400; }
    .bars {
      display: flex;
      align-items: end;
      gap: 6px;
      height: 168px;
      padding-top: 8px;
    }
    .bar-wrap {
      display: flex;
      flex: 1;
      min-width: 0;
      height: 100%;
      flex-direction: column;
      justify-content: end;
      align-items: center;
      gap: 4px;
    }
    .bar-value {
      color: var(--muted);
      font-size: 10px;
      font-variant-numeric: tabular-nums;
      line-height: 1;
    }
    .bar {
      width: 100%;
      min-height: 3px;
      border-radius: 2px 2px 0 0;
      background: var(--fill);
    }
    .bar-empty { background: var(--empty); }
    .bar-current {
      background: var(--ink);
    }
    .bar-label {
      color: var(--faint);
      font-size: 10px;
      font-variant-numeric: tabular-nums;
      white-space: nowrap;
    }
    .bar-label-current { color: var(--ink); font-weight: 650; }
    .version-note {
      margin-top: 10px;
      color: var(--muted);
      font-size: 12px;
    }
    .version-note strong { color: var(--ink); font-weight: 650; }
    .rows { display: grid; gap: 10px; }
    .row {
      display: grid;
      grid-template-columns: 108px 1fr 40px;
      align-items: center;
      gap: 10px;
    }
    .row-name {
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      font-size: 12px;
    }
    .track {
      height: 7px;
      overflow: hidden;
      border-radius: 1px;
      background: var(--track);
    }
    .fill {
      display: block;
      height: 100%;
      width: 0;
      background: var(--fill);
    }
    .fill-soft { background: var(--fill-soft); }
    .number {
      color: var(--muted);
      font-size: 12px;
      font-variant-numeric: tabular-nums;
      text-align: right;
    }
    .service-block + .service-block { margin-top: 16px; }
    .service-label {
      margin: 0 0 8px;
      color: var(--muted);
      font-size: 11px;
      letter-spacing: .06em;
      text-transform: uppercase;
    }
    .empty { color: var(--muted); font-size: 12px; }
    footer {
      display: flex;
      flex-wrap: wrap;
      justify-content: space-between;
      gap: 12px;
      margin-top: 28px;
      padding-top: 14px;
      border-top: 1px solid var(--line);
      color: var(--muted);
      font-size: 12px;
    }
    @media (max-width: 860px) {
      .stats { grid-template-columns: repeat(2, 1fr); }
      .grid { grid-template-columns: 1fr 1fr; }
      .span-2, .span-3 { grid-column: span 2; }
    }
    @media (max-width: 560px) {
      main { width: calc(100% - 28px); padding-top: 28px; }
      .stats, .grid { grid-template-columns: 1fr; }
      .span-2, .span-3 { grid-column: span 1; }
      .row { grid-template-columns: 84px 1fr 36px; }
    }
  </style>
</head>
<body>
  <main>
    <header>
      <a class="stars" id="stars" href="https://github.com/michellzappa/headroom" rel="noopener noreferrer">
        <span class="count" id="star-count">…</span>
        <span class="label">GitHub stars</span>
      </a>
      <p class="kicker">Headroom telemetry</p>
      <h1>Community Pulse</h1>
      <p class="lede">Public aggregates from opted-in Macs. One batch per Mac per week. Groups smaller than the privacy floor are withheld.</p>
      <div class="meta" id="meta">Loading community snapshot…</div>
    </header>

    <section class="stats" id="stats"></section>
    <section class="grid" id="body"></section>

    <footer>
      <span>Aggregates only. No prompts, identities, IPs, or raw model names.</span>
      <span><a href="https://github.com/michellzappa/headroom/tree/main/telemetry">Source</a> · <a href="https://github.com/michellzappa/headroom/blob/main/docs/telemetry.md">Privacy contract</a></span>
    </footer>
  </main>
  <script>
    const esc = (value) => String(value ?? '').replace(/[&<>\"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '\"': '&quot;', "'": '&#39;' }[char]));
    const title = (value) => String(value).replace(/[-_]/g, ' ').replace(/\\b\\w/g, (char) => char.toUpperCase());
    const number = (value) => value == null ? '—' : value.toLocaleString();
    const empty = (message) => '<div class="empty">' + esc(message) + '</div>';
    const pct = (count, total) => total ? Math.round(count / total * 100) : 0;
    const regionNames = (typeof Intl !== 'undefined' && Intl.DisplayNames)
      ? new Intl.DisplayNames(['en'], { type: 'region' })
      : null;
    const countryName = (code) => {
      try { return regionNames?.of(code) || code; } catch { return code; }
    };

    function countRows(items, total, soft) {
      if (!items.length) return empty('Below privacy floor');
      return '<div class="rows">' + items.map((item) => {
        const width = pct(item.count, total);
        return '<div class="row"><span class="row-name" title="' + esc(item.name) + '">' + esc(title(item.name)) + '</span><span class="track"><span class="fill' + (soft ? ' fill-soft' : '') + '" style="width:' + width + '%"></span></span><span class="number">' + esc(item.count) + '</span></div>';
      }).join('') + '</div>';
    }

    function shareRows(items) {
      if (!items.length) return empty('Below privacy floor');
      return '<div class="rows">' + items.map((item) => {
        const parts = item.name.split(':');
        const name = parts.length > 1
          ? title(parts[0]) + ' · ' + title(parts[1])
          : title(item.name);
        return '<div class="row"><span class="row-name" title="' + esc(item.name) + '">' + esc(name) + '</span><span class="track"><span class="fill" style="width:' + item.share + '%"></span></span><span class="number">' + esc(item.share) + '%</span></div>';
      }).join('') + '</div>';
    }

    function featureRows(items) {
      if (!items.length) return empty('Below privacy floor');
      return '<div class="rows">' + items.map((item) => {
        return '<div class="row"><span class="row-name" title="' + esc(item.name) + '">' + esc(title(item.name)) + '</span><span class="track"><span class="fill" style="width:' + item.adoption + '%"></span></span><span class="number">' + esc(item.adoption) + '%</span></div>';
      }).join('') + '</div>';
    }

    function servicePanel(services, total) {
      const blocks = [
        ['Enabled', services.enabled || []],
        ['Used', services.used || []],
        ['Healthy', services.healthy || []],
      ];
      if (blocks.every(([, items]) => !items.length)) return empty('Below privacy floor');
      return blocks.map(([label, items]) =>
        '<div class="service-block"><div class="service-label">' + esc(label) + '</div>' + countRows(items, total, label !== 'Used') + '</div>'
      ).join('');
    }

    function weekDelta(weeks) {
      const published = (weeks || []).filter((item) => item.count != null);
      if (published.length < 2) return null;
      const latest = published[published.length - 1].count;
      const previous = published[published.length - 2].count;
      return latest - previous;
    }

    function weeklyChart(weeks) {
      if (!weeks.length) return empty('No weekly history yet');
      const max = Math.max(1, ...weeks.map((item) => item.count || 0));
      return '<div class="bars">' + weeks.map((item) => {
        const height = Math.max(3, ((item.count || 0) / max) * 128);
        const label = item.count == null ? '·' : String(item.count);
        return '<div class="bar-wrap" title="' + esc(item.period) + (item.count == null ? ' · withheld or empty' : '') + '">' +
          '<div class="bar-value">' + esc(label) + '</div>' +
          '<div class="bar' + (item.count == null ? ' bar-empty' : '') + '" style="height:' + height + 'px"></div>' +
          '<div class="bar-label">' + esc(item.period.slice(6)) + '</div>' +
        '</div>';
      }).join('') + '</div>';
    }

    function versionParts(value) {
      return String(value).split(/[.+-]/).map((part) => {
        const number = Number.parseInt(part, 10);
        return Number.isFinite(number) ? number : part;
      });
    }

    function compareVersions(left, right) {
      const a = versionParts(left);
      const b = versionParts(right);
      const length = Math.max(a.length, b.length);
      for (let index = 0; index < length; index += 1) {
        const x = a[index] ?? 0;
        const y = b[index] ?? 0;
        if (x === y) continue;
        if (typeof x === 'number' && typeof y === 'number') return x - y;
        return String(x).localeCompare(String(y));
      }
      return 0;
    }

    function versionHistogram(versions, total, release) {
      if (!versions.length) return empty('Below privacy floor');
      const sorted = versions.slice().sort((lhs, rhs) => compareVersions(lhs.name, rhs.name));
      const max = Math.max(1, ...sorted.map((item) => item.count));
      const releaseVersion = release?.version || null;
      const onLatest = releaseVersion
        ? sorted.find((item) => item.name === releaseVersion)
        : null;
      const covered = sorted.reduce((sum, item) => sum + item.count, 0);
      const onLatestShare = onLatest && covered
        ? Math.round(onLatest.count / covered * 100)
        : null;
      const bars = '<div class="bars">' + sorted.map((item) => {
        const height = Math.max(3, (item.count / max) * 128);
        const isCurrent = releaseVersion != null && item.name === releaseVersion;
        return '<div class="bar-wrap" title="' + esc(item.name) + ': ' + esc(item.count) + ' Macs' + (isCurrent ? ' · latest release' : '') + '">' +
          '<div class="bar-value">' + esc(item.count) + '</div>' +
          '<div class="bar' + (isCurrent ? ' bar-current' : '') + '" style="height:' + height + 'px"></div>' +
          '<div class="bar-label' + (isCurrent ? ' bar-label-current' : '') + '">' + esc(item.name) + '</div>' +
        '</div>';
      }).join('') + '</div>';
      let note = '';
      if (releaseVersion) {
        note = '<div class="version-note">Latest release <strong>' + esc(releaseVersion) + '</strong>' +
          (onLatestShare == null
            ? ' · no published bucket on that version yet'
            : ' · <strong>' + esc(onLatestShare) + '%</strong> of published Macs on it') +
          '</div>';
      }
      return bars + note;
    }

    function panel(titleText, subtitle, body, span) {
      return '<div class="panel' + (span ? ' span-' + span : '') + '"><h2 class="section-title">' + esc(titleText) + '<small>' + esc(subtitle) + '</small></h2>' + body + '</div>';
    }

    function render(data) {
      const latest = data.latest;
      const floor = data.privacy.minimum_group_size;
      const release = data.latest_release;
      document.querySelector('#meta').textContent = latest
        ? 'Snapshot ' + latest.period + ' · published ' + data.generated_on + ' · groups smaller than ' + floor + ' withheld'
        : 'Waiting for at least ' + floor + ' reporting Macs in a week.';

      if (!latest) {
        document.querySelector('#stats').innerHTML =
          '<div class="panel stat"><div class="label">Weekly active Macs</div><div class="value">—</div><div class="sub">Below privacy floor</div></div>';
        document.querySelector('#body').innerHTML =
          panel('Weekly active Macs', 'ISO weeks in retention window', weeklyChart(data.weekly_active_macs || []), 3);
        return;
      }

      const total = latest.reporting_macs;
      const delta = weekDelta(data.weekly_active_macs);
      const deltaLabel = delta == null ? 'Need two published weeks' : (delta > 0 ? '+' + delta : String(delta)) + ' vs prior week';
      const topBuild = latest.versions?.[0];
      const topArch = latest.architectures?.[0];
      const releaseLabel = release?.version || '—';

      document.querySelector('#stats').innerHTML =
        '<div class="panel stat"><div class="label">Weekly active Macs</div><div class="value">' + esc(number(total)) + '</div><div class="sub">' + esc(latest.period) + '</div></div>' +
        '<div class="panel stat"><div class="label">Week-over-week</div><div class="value">' + esc(delta == null ? '—' : (delta > 0 ? '+' + delta : String(delta))) + '</div><div class="sub">' + esc(deltaLabel) + '</div></div>' +
        '<div class="panel stat"><div class="label">Latest release</div><div class="value">' + esc(releaseLabel) + '</div><div class="sub">' + esc(release?.published ? release.published.slice(0, 10) : 'update feed') + '</div></div>' +
        '<div class="panel stat"><div class="label">Top architecture</div><div class="value">' + esc(topArch?.name || '—') + '</div><div class="sub">' + esc(topArch ? topArch.count + ' Macs' : 'Below privacy floor') + '</div></div>';

      document.querySelector('#body').innerHTML =
        panel('Weekly active Macs', 'ISO weeks · empty or withheld weeks stay on the axis', weeklyChart(data.weekly_active_macs || []), 3) +
        panel('Version distribution', release?.version ? ('histogram · latest ' + release.version + ' marked') : 'histogram · app version', versionHistogram(latest.versions || [], total, release), 3) +
        panel('Architecture', 'CPU family', countRows(latest.architectures || [], total), 1) +
        panel('macOS major', 'major version', countRows((latest.macos_majors || []).map((item) => ({ name: 'macOS ' + item.name, count: item.count })), total), 1) +
        panel('Countries', 'Cloudflare edge geo · ISO code only, never an IP', countRows((latest.countries || []).map((item) => ({ name: countryName(item.name), count: item.count })), total), 1) +
        panel('Services', 'enabled · used · healthy', servicePanel(latest.services || {}, total), 2) +
        panel('Model family mix', 'average share among reporting Macs', shareRows(latest.model_shares || []), 1) +
        panel('Feature adoption', 'share of reporting Macs with flag on', featureRows(latest.features || []), 3);
    }

    fetch('/v1/community')
      .then((response) => response.json())
      .then(render)
      .catch(() => {
        document.querySelector('#meta').textContent = 'Community snapshot temporarily unavailable.';
      });

    fetch('https://api.github.com/repos/michellzappa/headroom', {
      headers: { Accept: 'application/vnd.github+json' },
    })
      .then((response) => response.ok ? response.json() : Promise.reject())
      .then((repo) => {
        const count = Number(repo.stargazers_count);
        if (!Number.isFinite(count)) return;
        document.querySelector('#star-count').textContent = count.toLocaleString();
      })
      .catch(() => {
        document.querySelector('#stars').hidden = true;
      });
  </script>
</body>
</html>`;

export function communityPage() {
  return COMMUNITY_PAGE;
}
