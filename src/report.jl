#=
* This file is part of OpenModelica.
*
* Copyright (c) 1998-CurrentYear, Open Source Modelica Consortium (OSMC),
* c/o Linköpings universitet, Department of Computer and Information Science,
* SE-58183 Linköping, Sweden.
*
* All rights reserved.
*
* THIS PROGRAM IS PROVIDED UNDER THE TERMS OF GPL VERSION 3 LICENSE OR
* THIS OSMC PUBLIC LICENSE (OSMC-PL) VERSION 1.2.
* ANY USE, REPRODUCTION OR DISTRIBUTION OF THIS PROGRAM CONSTITUTES
* RECIPIENT'S ACCEPTANCE OF THE OSMC PUBLIC LICENSE OR THE GPL VERSION 3,
* ACCORDING TO RECIPIENTS CHOICE.
*
* The OpenModelica software and the Open Source Modelica
* Consortium (OSMC) Public License (OSMC-PL) are obtained
* from OSMC, either from the above address,
* from the URLs: http:www.ida.liu.se/projects/OpenModelica or
* http:www.openmodelica.org, and in the OpenModelica distribution.
* GNU version 3 is obtained from: http:www.gnu.org/copyleft/gpl.html.
*
* This program is distributed WITHOUT ANY WARRANTY; without
* even the implied warranty of  MERCHANTABILITY or FITNESS
* FOR A PARTICULAR PURPOSE, EXCEPT AS EXPRESSLY SET FORTH
* IN THE BY RECIPIENT SELECTED SUBSIDIARY LICENSE CONDITIONS OF OSMC-PL.
*
* See the full OSMC Public License conditions for more details.
*
*/ =#

const DEFAULT_REPORTS_DIR = joinpath(@__DIR__, "..", "reports")

function phase_cell(results::Vector{PhaseResult}, target::Phase)
    idx = findfirst(r -> r.phase == target, results)
    if isnothing(idx)
        return "<td class=\"na\">&mdash;</td>"
    end
    r = results[idx]
    time_str = "$(round(r.time_s, digits=1))s"
    if r.success
        return "<td class=\"ok\">&#10003; $time_str</td>"
    else
        if isnothing(r.error)
            return "<td class=\"fail\">&#10007; $time_str</td>"
        else
            escaped = html_escape(r.error)
            return "<td class=\"fail\" data-error=\"$escaped\" onclick=\"showError(this)\">&#10007; $time_str</td>"
        end
    end
end

function html_escape(s::String)
    s = replace(s, "&" => "&amp;")
    s = replace(s, "<" => "&lt;")
    s = replace(s, ">" => "&gt;")
    s = replace(s, "\"" => "&quot;")
    return s
end

"""
    generate_report(results; format=:html, dir, changelog, msl_version, total_time,
                    filename="", name_tag="") -> String

Generate a timestamped coverage report and save it to `dir`.

`format` must be `:html` or `:markdown`.
`changelog` is an optional string describing changes since the last run.

Filename resolution (first non-empty wins):
  1. `filename` — absolute override. If it has no extension, the format extension is appended.
  2. `name_tag` — inserted into the default template: `coverage_{name_tag}_{yyyy-mm-dd_HHMM}.{ext}`.
  3. default template: `coverage_{yyyy-mm-dd_HHMM}.{ext}`.

Returns the path to the saved report file.
"""
function generate_report(results::Vector{ModelResult};
                         format::Symbol = :html,
                         dir::String = DEFAULT_REPORTS_DIR,
                         changelog::String = "",
                         msl_version::String = "3.2.3",
                         total_time::Float64 = 0.0,
                         filename::String = "",
                         name_tag::String = "")
    if format !== :html && format !== :markdown
        error("Invalid format $(repr(format)). Must be :html or :markdown.")
    end
    mkpath(dir)
    ts = Dates.format(Dates.now(), "yyyy-mm-dd_HHMM")
    ext = format === :html ? "html" : "md"
    fname = if !isempty(filename)
        isnothing(findfirst('.', filename)) ? "$(filename).$(ext)" : filename
    elseif !isempty(name_tag)
        "coverage_$(name_tag)_$(ts).$(ext)"
    else
        "coverage_$(ts).$(ext)"
    end
    filepath = joinpath(dir, fname)

    total = length(results)
    broken = count(r -> r.spec.expected == BROKEN, results)
    tested = total - broken
    frontend_pass = count(r -> r.highest >= FRONTEND, results)
    backend_pass = count(r -> r.highest >= BACKEND, results)
    simulate_pass = count(r -> r.highest >= SIMULATE, results)
    validate_pass = count(r -> r.highest >= VALIDATE, results)
    has_ref = count(r -> !isempty(r.spec.referenceFile) || !isempty(r.spec.reference), results)
    pct(n, d) = d > 0 ? "$(round(100 * n / d, digits = 1))%" : "N/A"

    content = if format === :html
        _generate_html(results, filepath, ts, total, broken, tested,
                       frontend_pass, backend_pass, simulate_pass, validate_pass,
                       has_ref, pct, changelog, msl_version, total_time)
    else
        _generate_markdown(results, filepath, ts, total, broken, tested,
                           frontend_pass, backend_pass, simulate_pass, validate_pass,
                           has_ref, pct, changelog)
    end

    write(filepath, content)
    @info "Report saved to $filepath"
    #= the compared signals next to it, for looking at how a model behaved (signals.jl) =#
    if format === :html
        local signalsPath = splitext(filepath)[1] * ".signals.json"
        write_signals(signalsPath, results) && @info "Signals saved to $signalsPath"
    end
    return filepath
end

function _generate_html(results, filepath, ts, total, broken, tested,
                        frontend_pass, backend_pass, simulate_pass, validate_pass,
                        has_ref, pct, changelog, msl_version, total_time)
    timestamp = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS")
    time_str = if total_time > 0
        mins = floor(Int, total_time / 60)
        secs = round(Int, total_time % 60)
        "$(mins) min $(secs) s"
    else
        ""
    end

    sorted_results = sort(results, by = x -> (x.spec.domain, x.spec.name))

    rows = IOBuffer()
    current_domain = ""
    for r in sorted_results
        if r.spec.domain != current_domain
            current_domain = r.spec.domain
            print(rows, """
            <tr class="domain-header">
              <td colspan="6"><strong>$(html_escape(current_domain))</strong></td>
            </tr>
            """)
        end
        row_class = r.spec.expected == BROKEN ? "broken-row" : ""
        name_short = replace(r.spec.name, "Modelica." => "")
        fe_cell = phase_cell(r.phases, FRONTEND)
        be_cell = phase_cell(r.phases, BACKEND)
        sim_cell = phase_cell(r.phases, SIMULATE)
        val_cell = phase_cell(r.phases, VALIDATE)
        total_model_time = sum(p.time_s for p in r.phases; init = 0.0)
        time_cell = isempty(r.phases) ? "&mdash;" : "$(round(total_model_time, digits=1))s"
        local signals_link = isempty(r.signals) ? "" : _signals_link(r)
        print(rows, """
        <tr class="$row_class">
          <td class="model-name">$name_short$signals_link</td>
          $fe_cell
          $be_cell
          $sim_cell
          $val_cell
          <td class="time">$time_cell</td>
        </tr>
        """)
    end

    changelog_html = if !isempty(changelog)
        "<div class=\"changelog\"><strong>Changes:</strong> $(html_escape(changelog))</div>"
    else
        ""
    end

    return """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <title>Modelica $msl_version - OM.jl Pipeline Test Results</title>
    <style>
      body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
             margin: 2em; background: #fff; color: #333; }
      h1 { margin-bottom: 0.2em; }
      .meta { color: #666; font-size: 0.9em; margin-bottom: 0.5em; }
      .meta code { background: #f0f0f0; padding: 2px 6px; border-radius: 3px; }
      .changelog { color: #555; font-size: 0.9em; margin-bottom: 1.5em; }
      .summary-table { border-collapse: collapse; margin-bottom: 2em; }
      .summary-table th, .summary-table td { border: 1px solid #ccc; padding: 6px 16px; text-align: right; }
      .summary-table th { background: #f5f5f5; text-align: left; }
      .summary-table td:last-child { font-weight: bold; }
      table.results { border-collapse: collapse; width: 100%; }
      table.results th { border: 1px solid #ccc; padding: 4px 10px; background: #f5f5f5;
                         text-align: left; font-size: 0.85em; text-transform: uppercase; }
      table.results td { border: 1px solid #ccc; padding: 4px 10px; font-size: 0.9em; }
      .model-name { font-family: monospace; font-size: 0.85em; }
      .ok { background: #d4edda; color: #155724; text-align: center; }
      .fail { background: #f8d7da; color: #721c24; text-align: center; cursor: pointer; }
      .fail[data-error]:hover { text-decoration: underline dotted; }
      #error-modal { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.45);
                     z-index: 1000; align-items: center; justify-content: center; }
      #error-modal.open { display: flex; }
      #error-modal-box { background: #fff; border-radius: 6px; padding: 1.5em 2em;
                         max-width: 70vw; max-height: 80vh; overflow-y: auto;
                         box-shadow: 0 8px 32px rgba(0,0,0,0.25); position: relative; }
      #error-modal-close { position: absolute; top: 0.6em; right: 0.8em;
                           font-size: 1.3em; cursor: pointer; color: #555; border: none;
                           background: none; }
      #error-modal-close:hover { color: #000; }
      #error-modal-text { font-family: monospace; font-size: 0.85em; white-space: pre-wrap;
                          color: #721c24; margin-top: 0.5em; }
      .na { color: #888; text-align: center; }
      .time { text-align: right; color: #666; font-family: monospace; }
      .broken-row { opacity: 0.5; }
      .broken-row td { font-style: italic; }
      .domain-header td { background: #e9ecef; font-size: 0.85em; padding: 6px 10px; }
    $(_SIGNALS_CSS)
    </style>
    </head>
    <body>
    <h1>Modelica $msl_version - OM.jl Pipeline Test Results</h1>
    <div class="meta">
      Generated: $timestamp$(isempty(time_str) ? "" : " | Total runtime: $time_str") | $total models ($broken known broken)
    </div>
    $changelog_html

    <table class="summary-table">
    <tr><th>Stage</th><th>Passed</th><th>Total</th><th>Rate</th></tr>
    <tr><td>Frontend</td><td>$frontend_pass</td><td>$total</td><td>$(pct(frontend_pass, total))</td></tr>
    <tr><td>Backend</td><td>$backend_pass</td><td>$total</td><td>$(pct(backend_pass, total))</td></tr>
    <tr><td>Simulate</td><td>$simulate_pass</td><td>$total</td><td>$(pct(simulate_pass, total))</td></tr>
    <tr><td>Validate</td><td>$validate_pass</td><td>$total</td><td>$(pct(validate_pass, total))</td></tr>
    </table>

    <table class="results">
    <thead>
    <tr>
      <th>Model</th>
      <th>Frontend</th>
      <th>Backend</th>
      <th>Simulate</th>
      <th>Validate</th>
      <th>Time</th>
    </tr>
    </thead>
    <tbody>
    $(String(take!(rows)))
    </tbody>
    </table>
    <div id="error-modal">
      <div id="error-modal-box">
        <button id="error-modal-close" onclick="closeError()" title="Close">&times;</button>
        <strong id="error-modal-title">Error detail</strong>
        <pre id="error-modal-text"></pre>
      </div>
    </div>
    <script>
      function showError(td) {
        var msg = td.getAttribute('data-error');
        if (!msg) return;
        document.getElementById('error-modal-title').textContent = 'Error detail';
        document.getElementById('error-modal-text').className = '';
        document.getElementById('error-modal-text').textContent = msg;
        document.getElementById('error-modal').classList.add('open');
      }
      function closeError() {
        document.getElementById('error-modal').classList.remove('open');
      }
      document.getElementById('error-modal').addEventListener('click', function(e) {
        if (e.target === this) closeError();
      });
      document.addEventListener('keydown', function(e) {
        if (e.key === 'Escape') closeError();
      });
    </script>
    <script>
    $(_SIGNALS_JS)
    </script>
    </body>
    </html>
    """
end

#= A model's link to the signals its validation compared (signals.jl): how many passed of how many. =#
function _signals_link(r::ModelResult)::String
    local n::Int = length(r.signals)
    local passed::Int = count(s -> s.passed, r.signals)
    local cls::String = passed < n ? "sig-link sig-has-fail" : "sig-link"
    return " <a class=\"$cls\" href=\"#\" data-model=\"$(html_escape(r.spec.name))\" " *
           "onclick=\"return toggleSignals(this)\" title=\"The signals the validation compared\">signals $passed/$n</a>"
end

const _SIGNALS_CSS = raw"""
      .sig-link { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                  font-size: 0.85em; margin-left: 0.6em; color: #0366d6; text-decoration: none; white-space: nowrap; }
      .sig-link:hover { text-decoration: underline; }
      .sig-link.sig-has-fail { color: #b31d28; font-weight: 600; }
      .sig-row > td { background: #fafbfc; padding: 10px 12px; }
      .sig-head { font-size: 0.85em; color: #555; margin-bottom: 8px; }
      .sig-key-ref { color: #555; font-weight: 600; }
      .sig-key-omjl { color: #0366d6; font-weight: 600; }
      .sig-grid { display: flex; flex-wrap: wrap; gap: 12px; }
      .sig-card { border: 1px solid #ddd; border-radius: 4px; background: #fff; padding: 6px 8px; width: 376px; }
      .sig-card.sig-fail { border-color: #e4a3a8; }
      .sig-title { font-family: monospace; font-size: 0.85em; word-break: break-all; }
      .sig-title a { color: #333; text-decoration: none; }
      .sig-title a:hover { text-decoration: underline; }
      .sig-mark-ok { color: #155724; }
      .sig-mark-fail { color: #b31d28; font-weight: 600; }
      .sig-stats, .sig-readout { font-size: 0.75em; color: #666; font-family: monospace; min-height: 1.3em; }
      .sig-plot { display: block; max-width: 100%; height: auto; }
      .sig-plot .frame { fill: none; stroke: #ddd; }
      .sig-plot .band { fill: #e6e6e6; }
      .sig-plot .ref { fill: none; stroke: #555; stroke-width: 1.5; }
      .sig-plot .omjl { fill: none; stroke: #0366d6; stroke-width: 1.5; stroke-dasharray: 5 3; }
      .sig-plot .worst { fill: none; stroke: #b31d28; stroke-width: 2; }
      .sig-plot .cursor { stroke: #999; stroke-dasharray: 2 2; }
      .sig-plot text { font-size: 10px; fill: #666; font-family: monospace; }
      #error-modal-text.values { color: #333; }
"""

#= The viewer of a model's compared signals: the run's signals.json (on the site), or the report's
   <name>.signals.json beside it, read on the first click; a report opened from disk cannot read a
   file, so it asks for it. =#
const _SIGNALS_JS = raw"""
var SIGNALS = null, SIGNALS_LOADING = null, SVGNS = 'http://www.w3.org/2000/svg';
function signalFiles() {
  var page = location.pathname.split('/').pop() || 'report.html';
  return [page.replace(/\.html?$/, '') + '.signals.json', 'signals.json'];
}
function loadSignals() {
  if (SIGNALS) return Promise.resolve(SIGNALS);
  if (SIGNALS_LOADING) return SIGNALS_LOADING;
  SIGNALS_LOADING = signalFiles().reduce(function(p, f) {
    return p.catch(function() {
      return fetch(f).then(function(r) { if (!r.ok) throw new Error(f + ': ' + r.status); return r.json(); });
    });
  }, Promise.reject(new Error('none'))).then(function(d) { SIGNALS = d.models; return SIGNALS; });
  SIGNALS_LOADING.catch(function() { SIGNALS_LOADING = null; });
  return SIGNALS_LOADING;
}
function toggleSignals(a) {
  var tr = a.closest('tr'), next = tr.nextElementSibling;
  if (next && next.classList.contains('sig-row')) { next.remove(); return false; }
  var row = document.createElement('tr'), td = document.createElement('td');
  row.className = 'sig-row'; td.colSpan = 6; row.appendChild(td);
  tr.parentNode.insertBefore(row, tr.nextSibling);
  td.textContent = 'Loading the signals...';
  var model = a.getAttribute('data-model');
  loadSignals().then(function(models) { showModel(td, models, model); },
                     function() { askForFile(td, model); });
  return false;
}
function showModel(td, models, model) {
  if (models[model]) renderSignals(td, models[model]);
  else td.textContent = 'The signals file has no signals of ' + model + '.';
}
function askForFile(td, model) {
  td.textContent = '';
  var p = document.createElement('p');
  p.textContent = 'The signals could not be read. The coverage site keeps them (signals.json) for the latest 5 runs ' +
    'of a version; a report opened from disk cannot read the .signals.json beside it: choose that file here. ';
  var input = document.createElement('input');
  input.type = 'file'; input.accept = '.json,application/json';
  input.onchange = function() {
    if (!input.files[0]) return;
    input.files[0].text().then(function(t) { SIGNALS = JSON.parse(t).models; showModel(td, SIGNALS, model); });
  };
  p.appendChild(input); td.appendChild(p);
}
function fmt(x) {
  if (x === null || x === undefined) return '—';
  var a = Math.abs(x);
  return (a !== 0 && (a >= 1e5 || a < 1e-3)) ? x.toExponential(3) : String(Number(x.toPrecision(6)));
}
function fmtAxis(x) {
  var a = Math.abs(x);
  return (a !== 0 && (a >= 1e5 || a < 1e-3)) ? x.toExponential(2) : String(Number(x.toPrecision(4)));
}
function sampleTimes(s, m) {
  var T = s.time || m.time, n = T[2], t = [];
  for (var i = 0; i < n; i++) t.push(n > 1 ? T[0] + i * (T[1] - T[0]) / (n - 1) : T[0]);
  return t;
}
function renderSignals(td, m) {
  td.textContent = '';
  var sigs = m.signals.slice().sort(function(x, y) { return x.passed - y.passed; });   // failed first
  var failed = sigs.filter(function(s) { return !s.passed; }).length;
  var head = document.createElement('div');
  head.className = 'sig-head';
  head.innerHTML = '<span class="sig-key-ref">— reference</span> &nbsp; <span class="sig-key-omjl">- - OM.jl</span> &nbsp; ' +
    'grey: the tolerance around the reference (atol ' + fmt(m.atol) + ', reltol ' + fmt(m.reltol) + '); values with 6 significant digits. ';
  head.appendChild(document.createTextNode(sigs.length + ' signals compared, ' + failed + ' outside the tolerance' +
    (m.validated ? '.' : '; the model did not validate.') + ' Point at a plot to read its values; click a name for all of them.'));
  td.appendChild(head);
  var grid = document.createElement('div');
  grid.className = 'sig-grid';
  sigs.forEach(function(s) { grid.appendChild(signalCard(s, m)); });
  td.appendChild(grid);
}
function signalCard(s, m) {
  var card = document.createElement('div'), title = document.createElement('div'), name = document.createElement('a');
  var mark = document.createElement('span'), stats = document.createElement('div'), readout = document.createElement('div');
  card.className = 'sig-card ' + (s.passed ? 'sig-pass' : 'sig-fail');
  title.className = 'sig-title';
  name.href = '#'; name.textContent = s.name; name.title = 'All compared values';
  name.onclick = function() { showValues(s, m); return false; };
  mark.className = s.passed ? 'sig-mark-ok' : 'sig-mark-fail';
  mark.textContent = s.passed ? ' ✓' : ' ✗ outside the tolerance';
  title.appendChild(name); title.appendChild(mark);
  stats.className = 'sig-stats';
  stats.textContent = s.max_abs_err === null ? 'not compared: no OM.jl value' :
    'max |error| ' + fmt(s.max_abs_err) + ' (relative ' + fmt(s.max_rel_err) + ') at t = ' + fmt(s.worst_time);
  readout.className = 'sig-readout';
  card.appendChild(title); card.appendChild(stats); card.appendChild(signalPlot(s, m, readout)); card.appendChild(readout);
  return card;
}
function svgEl(name, attrs) {
  var e = document.createElementNS(SVGNS, name);
  for (var k in attrs) e.setAttribute(k, attrs[k]);
  return e;
}
function svgText(svg, x, y, s, anchor) {
  var t = svgEl('text', {x: x, y: y, 'text-anchor': anchor});
  t.textContent = s; svg.appendChild(t);
}
function svgLine(svg, t, v, X, Y, cls) {   // one polyline per run of values (none where null)
  var pts = [];
  function flush() { if (pts.length) svg.appendChild(svgEl('polyline', {points: pts.join(' '), 'class': cls})); pts = []; }
  for (var i = 0; i < t.length; i++) { if (v[i] === null) flush(); else pts.push(X(t[i]) + ',' + Y(v[i])); }
  flush();
}
function signalPlot(s, m, readout) {
  var W = 360, H = 160, L = 62, R = 8, T = 8, B = 20;
  var t = sampleTimes(s, m), ref = s.reference, om = s.omjl, n = t.length, i;
  var tol = ref.map(function(v) { return v === null ? null : m.atol + m.reltol * Math.abs(v); });
  var ys = [];
  for (i = 0; i < n; i++) {
    if (ref[i] !== null) ys.push(ref[i] + tol[i], ref[i] - tol[i]);
    if (om[i] !== null) ys.push(om[i]);
  }
  var y0 = ys.length ? Math.min.apply(null, ys) : 0, y1 = ys.length ? Math.max.apply(null, ys) : 1;
  if (y1 - y0 <= 1e-12 * Math.max(1, Math.abs(y1))) { var c = y0, d = 1e-6 * Math.max(1, Math.abs(c)); y0 = c - d; y1 = c + d; }
  var pad = 0.05 * (y1 - y0); y0 -= pad; y1 += pad;
  var t0 = t[0], t1 = t[n - 1] > t0 ? t[n - 1] : t0 + 1;
  function X(x) { return L + (x - t0) / (t1 - t0) * (W - L - R); }
  function Y(y) { return T + (y1 - y) / (y1 - y0) * (H - T - B); }
  var svg = svgEl('svg', {viewBox: '0 0 ' + W + ' ' + H, width: W, height: H, 'class': 'sig-plot'});
  svg.appendChild(svgEl('rect', {x: L, y: T, width: W - L - R, height: H - T - B, 'class': 'frame'}));
  var up = [], lo = [];
  for (i = 0; i < n; i++) if (ref[i] !== null) { up.push(X(t[i]) + ',' + Y(ref[i] + tol[i])); lo.unshift(X(t[i]) + ',' + Y(ref[i] - tol[i])); }
  if (up.length) svg.appendChild(svgEl('polygon', {points: up.concat(lo).join(' '), 'class': 'band'}));
  svgLine(svg, t, ref, X, Y, 'ref');
  svgLine(svg, t, om, X, Y, 'omjl');
  if (!s.passed && s.worst_time !== null) {
    var w = Math.round((s.worst_time - t0) / (t1 - t0) * (n - 1));
    w = Math.max(0, Math.min(n - 1, w));
    if (om[w] !== null) svg.appendChild(svgEl('circle', {cx: X(t[w]), cy: Y(om[w]), r: 4, 'class': 'worst'}));
  }
  svgText(svg, L - 4, T + 9, fmtAxis(y1 - pad), 'end');
  svgText(svg, L - 4, H - B, fmtAxis(y0 + pad), 'end');
  svgText(svg, L, H - 5, fmtAxis(t[0]), 'start');
  svgText(svg, W - R, H - 5, 't = ' + fmtAxis(t[n - 1]), 'end');
  var cursor = svgEl('line', {y1: T, y2: H - B, 'class': 'cursor', visibility: 'hidden'});
  svg.appendChild(cursor);
  var hit = svgEl('rect', {x: L, y: T, width: W - L - R, height: H - T - B, fill: 'transparent'});
  hit.addEventListener('mousemove', function(ev) {
    var box = svg.getBoundingClientRect(), x = (ev.clientX - box.left) * W / box.width;
    var k = Math.max(0, Math.min(n - 1, Math.round((x - L) / (W - L - R) * (n - 1))));
    cursor.setAttribute('x1', X(t[k])); cursor.setAttribute('x2', X(t[k])); cursor.setAttribute('visibility', 'visible');
    readout.textContent = 't = ' + fmt(t[k]) + '  reference ' + fmt(ref[k]) + '  OM.jl ' + fmt(om[k]) +
      (ref[k] !== null && om[k] !== null ? '  |diff| ' + fmt(Math.abs(om[k] - ref[k])) : '');
  });
  hit.addEventListener('mouseleave', function() { cursor.setAttribute('visibility', 'hidden'); readout.textContent = ''; });
  svg.appendChild(hit);
  return svg;
}
function showValues(s, m) {
  var t = sampleTimes(s, m), lines = [];
  function pad(text) { return (text + '                ').slice(0, 16); }
  lines.push(pad('t') + pad('reference') + pad('OM.jl') + '|diff|');
  for (var i = 0; i < t.length; i++) {
    var r = s.reference[i], o = s.omjl[i];
    lines.push(pad(fmt(t[i])) + pad(fmt(r)) + pad(fmt(o)) + (r !== null && o !== null ? fmt(Math.abs(o - r)) : '—'));
  }
  document.getElementById('error-modal-title').textContent = s.name + ': the compared values';
  var pre = document.getElementById('error-modal-text');
  pre.className = 'values'; pre.textContent = lines.join('\n');
  document.getElementById('error-modal').classList.add('open');
}
"""

function _generate_markdown(results, filepath, ts, total, broken, tested,
                            frontend_pass, backend_pass, simulate_pass, validate_pass,
                            has_ref, pct, changelog)
    categories = categorize_results(results)
    sorted_cats = sort(collect(categories), by = x -> length(x[2]), rev = true)

    io = IOBuffer()
    println(io, "# MSL Coverage Report")
    println(io, "")
    println(io, "Date: $ts")
    println(io, "")
    if !isempty(changelog)
        println(io, "## Changes Since Last Report")
        println(io, "")
        println(io, changelog)
        println(io, "")
    end
    println(io, "## Summary")
    println(io, "")
    println(io, "| Stage | Passed | Total | Rate |")
    println(io, "|-------|--------|-------|------|")
    println(io, "| Frontend | $frontend_pass | $total | $(pct(frontend_pass, total)) |")
    println(io, "| Backend | $backend_pass | $total | $(pct(backend_pass, total)) |")
    println(io, "| Simulate | $simulate_pass | $total | $(pct(simulate_pass, total)) |")
    println(io, "| Validate | $validate_pass | $total | $(pct(validate_pass, total)) |")
    println(io, "")
    println(io, "Known broken: $broken")
    println(io, "")
    println(io, "## Error Breakdown")
    println(io, "")
    println(io, "| Count | Category |")
    println(io, "|-------|----------|")
    for (cat, models) in sorted_cats
        println(io, "| $(length(models)) | $cat |")
    end
    println(io, "")
    println(io, "## Error Details")
    println(io, "")
    for (cat, models) in sorted_cats
        println(io, "### $cat ($(length(models)))")
        println(io, "")
        for m in sort(models)
            println(io, "- $m")
        end
        println(io, "")
    end
    #= Per-phase failure lists. A model is "stuck at phase X" when it
       succeeded through phase X but failed at X+1 (or X is the highest it
       reached). Skip models marked `broken` since those are expected to
       fail. The error message snippet helps triage clusters without
       jumping to the full result vector. =#
    function _failures_stuck_at(phase::Phase)
        out = ModelResult[]
        for r in results
            r.spec.expected == BROKEN && continue
            local fePhases = Dict(p.phase => p for p in r.phases)
            local feOk = get(fePhases, FRONTEND, nothing) !== nothing &&
                         fePhases[FRONTEND].success
            feOk || continue
            if r.highest == phase
                push!(out, r)
            end
        end
        sort!(out; by = r -> r.spec.name)
        return out
    end
    function _print_failure_section(label::String, phase::Phase)
        local fails = _failures_stuck_at(phase)
        println(io, "## $label ($(length(fails)))")
        println(io, "")
        if isempty(fails)
            println(io, "_None_")
            println(io, "")
            return
        end
        for r in fails
            #= Prefer the runtime error captured by the failed PhaseResult
               (first phase with success=false); fall back to the static
               issue annotation from the discovery override file. =#
            local err = ""
            for pr in r.phases
                if !pr.success && pr.error !== nothing && !isempty(pr.error)
                    err = pr.error
                    break
                end
            end
            if isempty(err)
                err = r.spec.issue
            end
            local snippet = isempty(err) ? "_no error message_" :
                            first(replace(err, '\n' => ' '), 200)
            println(io, "- `$(r.spec.name)` — $snippet")
        end
        println(io, "")
    end
    _print_failure_section("Backend failures (Frontend✓, Backend✗)", FRONTEND)
    _print_failure_section("Simulate failures (Backend✓, Simulate✗)", BACKEND)
    _print_failure_section("Validate failures (Simulate✓, Validate✗)", SIMULATE)

    println(io, "## Passing Models ($(frontend_pass))")
    println(io, "")
    passing = sort([r.spec.name for r in results if r.highest >= FRONTEND])
    for m in passing
        println(io, "- $m")
    end
    println(io, "")

    return String(take!(io))
end

"""
    run_coverage_and_report(; <run_coverage kwargs...>,
                              format=:html, dir=DEFAULT_REPORTS_DIR,
                              changelog="", filename="", name_tag="")
                            -> Vector{ModelResult}

Runs `run_coverage` with the given arguments, then automatically saves both an
HTML and a Markdown coverage report via `generate_report`. Returns the results vector.
"""
function run_coverage_and_report(; library::String = "Modelica",
                                   msl_version::String = "MSL:3.2.3",
                                   version::String = msl_library_version(msl_version),
                                   domain::String = "",
                                   model::String = "",
                                   filter::Regex = r"",
                                   overrides::String = default_models_path(version),
                                   timeout::Float64 = 1000.0,
                                   phases::Vector{Phase} = PHASE_ORDER,
                                   from_phase::Phase = FRONTEND,
                                   to_phase::Phase = VALIDATE,
                                   check_sim_code::Bool = false,
                                   n_workers::Int = max(1, nprocs() - 1),
                                   format::Symbol = :html,  # kept for compatibility; both html and md are always written
                                   dir::String = DEFAULT_REPORTS_DIR,
                                   changelog::String = "",
                                   filename::String = "",
                                   name_tag::String = "")::Vector{ModelResult}
    t_start = time()
    results = run_coverage(; library, version, msl_version, domain, model, filter,
                             overrides, timeout, phases, from_phase, to_phase,
                             check_sim_code, n_workers)
    total_time = time() - t_start
    html_path = generate_report(results; format=:html, dir, changelog, msl_version,
                                total_time, filename, name_tag)
    md_path   = generate_report(results; format=:markdown, dir, changelog, msl_version,
                                total_time, filename, name_tag)
    @info "Reports saved" html=html_path markdown=md_path
    return results
end
