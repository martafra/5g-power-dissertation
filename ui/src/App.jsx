import { useState, useEffect, useRef } from 'react'
import axios from 'axios'
import {
  LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer
} from 'recharts'
import './App.css'

const API = import.meta.env.VITE_API_URL || 'http://localhost:5000/api'
const POLL_INTERVAL = 5000

function App() {
  const [status, setStatus] = useState(null)
  const [breakdown, setBreakdown] = useState({})
  const [history, setHistory] = useState([])
  const [logs, setLogs] = useState([])
  const [scaleForm, setScaleForm] = useState({ cu: 1, du: 1 })
  const [autoscaleForm, setAutoscaleForm] = useState({
    min_cu: 1, max_cu: 3, du: 1,
    interval: 30, consecutive: 2, cooldown: 60,
    high_threshold: 3.0, low_threshold: 1.5
  })
  const [loadForm, setLoadForm] = useState({ sequence: '1,16,96,16,1', duration: 60, cqi: 15 })
  const [message, setMessage] = useState(null)
  const logsRef = useRef(null)

  const notify = (msg, ok = true) => {
    setMessage({ text: msg, ok })
    setTimeout(() => setMessage(null), 4000)
  }

  const fetchStatus = async () => {
    try {
      const [s, b] = await Promise.all([
        axios.get(`${API}/status`),
        axios.get(`${API}/metrics/breakdown`)
      ])
      setStatus(s.data)
      setBreakdown(b.data.components || {})
      setHistory(prev => {
        const next = [...prev, {
          t: new Date().toLocaleTimeString(),
          power: s.data.power_W,
          per_du: s.data.power_per_du_W
        }]
        return next.slice(-30)
      })
    } catch {}
  }

  const fetchLogs = async () => {
    try {
      const r = await axios.get(`${API}/metrics/history`)
      setLogs(r.data.events || [])
    } catch {}
  }

  useEffect(() => {
    fetchStatus()
    fetchLogs()
    const t1 = setInterval(fetchStatus, POLL_INTERVAL)
    const t2 = setInterval(fetchLogs, 15000)
    return () => { clearInterval(t1); clearInterval(t2) }
  }, [])

  useEffect(() => {
    if (logsRef.current) logsRef.current.scrollTop = logsRef.current.scrollHeight
  }, [logs])

  const handleScale = async () => {
    try {
      await axios.post(`${API}/scale`, scaleForm)
      notify(`Scaling to ${scaleForm.cu}CU-${scaleForm.du}DU...`)
    } catch { notify('Scale request failed', false) }
  }

  const handleTeardown = async () => {
    try {
      await axios.post(`${API}/teardown`, { all: false })
      notify('Tearing down RAN containers...')
    } catch { notify('Teardown failed', false) }
  }

  const handleAutoscale = async () => {
    if (status?.autoscale_running) {
      try {
        await axios.post(`${API}/autoscale/stop`)
        notify('Autoscaler stopped')
      } catch { notify('Failed to stop autoscaler', false) }
    } else {
      try {
        await axios.post(`${API}/autoscale/start`, autoscaleForm)
        notify('Autoscaler started')
      } catch { notify('Failed to start autoscaler', false) }
    }
  }

  const handleLoad = async () => {
    if (status?.load_running) {
      try {
        await axios.post(`${API}/load/stop`)
        notify('Load generator stopped')
      } catch { notify('Failed to stop load generator', false) }
    } else {
      try {
        await axios.post(`${API}/load/start`, loadForm)
        notify('Load generator started')
      } catch { notify('Failed to start load generator', false) }
    }
  }

  const topo = status?.topology

  // classify component name for bar colour
  const barClass = (name) => name.startsWith('srsran_du') ? 'bar-fill-du' : 'bar-fill-cu'

  return (
    <div className="app">

      {message && (
        <div className={`toast ${message.ok ? 'toast-ok' : 'toast-err'}`}>
          {message.text}
        </div>
      )}

      <header className="header">
        <div className="header-left">
          <span className="header-title">5G Power Platform</span>
          <span className="header-desc">
            Power consumption analysis of containerised 5G deployments with variable topologies and load
          </span>
          <span className="header-sub">srsRAN · Open5GS · CloudLab</span>
        </div>
        <div className="header-right">
          <div className="pill pill-topology">
            <span className="pill-label">topology</span>
            <span className="pill-value">{topo?.label ?? '—'}</span>
          </div>
          <div className="pill pill-power">
            <span className="pill-label">power</span>
            <span className="pill-value">{status ? `${status.power_W} W` : '—'}</span>
          </div>
          <div className="pill pill-perdu">
            <span className="pill-label">W / DU</span>
            <span className="pill-value">{status ? `${status.power_per_du_W} W` : '—'}</span>
          </div>
        </div>
      </header>

      <main className="grid">

        {/* power chart */}
        <section className="card span2">
          <h2>Power over time</h2>
          <ResponsiveContainer width="100%" height={200}>
            <LineChart data={history}>
              <CartesianGrid strokeDasharray="3 3" stroke="#e2dfd8" />
              <XAxis dataKey="t" tick={{ fontSize: 11, fill: '#9a9590' }} />
              <YAxis tick={{ fontSize: 11, fill: '#9a9590' }} unit=" W" />
              <Tooltip contentStyle={{ background: '#fff', border: '1px solid #e2dfd8', borderRadius: 8 }} />
              <Legend />
              <Line type="monotone" dataKey="power" name="Total (W)" stroke="#7ecece" dot={false} strokeWidth={2} />
              <Line type="monotone" dataKey="per_du" name="Per DU (W)" stroke="#8ecfa0" dot={false} strokeWidth={2} />
            </LineChart>
          </ResponsiveContainer>
        </section>

        {/* component breakdown */}
        <section className="card">
          <h2>Component breakdown</h2>
          {Object.keys(breakdown).length === 0
            ? <p className="muted">no data</p>
            : Object.entries(breakdown)
                .filter(([k]) => k.startsWith('srsran'))
                .sort((a, b) => b[1] - a[1])
                .map(([name, w]) => (
                  <div key={name} className="bar-row">
                    <span className="bar-label">{name.replace('srsran_', '')}</span>
                    <div className="bar-track">
                      <div
                        className={`bar-fill ${barClass(name)}`}
                        style={{ width: `${Math.min(100, (w / 5) * 100)}%` }}
                      />
                    </div>
                    <span className="bar-val">{w} W</span>
                  </div>
                ))
          }
        </section>

        {/* manual scaling */}
        <section className="card">
          <h2>Manual scaling</h2>
          <div className="form-row">
            <label>CU
              <input type="number" min="1" max="4" value={scaleForm.cu}
                onChange={e => setScaleForm(f => ({ ...f, cu: +e.target.value }))} />
            </label>
            <label>DU / CU
              <input type="number" min="1" max="4" value={scaleForm.du}
                onChange={e => setScaleForm(f => ({ ...f, du: +e.target.value }))} />
            </label>
          </div>
          <div className="btn-row">
            <button className="btn btn-primary" onClick={handleScale}>Scale</button>
            <button className="btn btn-danger" onClick={handleTeardown}>Teardown RAN</button>
          </div>
        </section>

        {/* autoscaler */}
        <section className="card">
          <h2>Autoscaler
            <span className={`badge ${status?.autoscale_running ? 'badge-on' : 'badge-off'}`}>
              {status?.autoscale_running ? 'running' : 'stopped'}
            </span>
          </h2>
          <div className="form-grid">
            {[
              ['Min CU', 'min_cu'], ['Max CU', 'max_cu'], ['DU / CU', 'du'],
              ['Interval (s)', 'interval'], ['Consecutive', 'consecutive'], ['Cooldown (s)', 'cooldown'],
              ['High threshold (W)', 'high_threshold'], ['Low threshold (W)', 'low_threshold']
            ].map(([label, key]) => (
              <label key={key}>{label}
                <input type="number" value={autoscaleForm[key]}
                  onChange={e => setAutoscaleForm(f => ({ ...f, [key]: +e.target.value }))} />
              </label>
            ))}
          </div>
          <button
            className={`btn ${status?.autoscale_running ? 'btn-danger' : 'btn-green'}`}
            onClick={handleAutoscale}>
            {status?.autoscale_running ? 'Stop autoscaler' : 'Start autoscaler'}
          </button>
        </section>

        {/* load generator */}
        <section className="card">
          <h2>Load generator
            <span className={`badge ${status?.load_running ? 'badge-on' : 'badge-off'}`}>
              {status?.load_running ? 'running' : 'stopped'}
            </span>
          </h2>
          <div className="form-row">
            <label>UE sequence
              <input type="text" value={loadForm.sequence}
                onChange={e => setLoadForm(f => ({ ...f, sequence: e.target.value }))} />
            </label>
          </div>
          <div className="form-row">
            <label>Duration / step (s)
              <input type="number" value={loadForm.duration}
                onChange={e => setLoadForm(f => ({ ...f, duration: +e.target.value }))} />
            </label>
            <label>CQI
              <input type="number" value={loadForm.cqi}
                onChange={e => setLoadForm(f => ({ ...f, cqi: +e.target.value }))} />
            </label>
          </div>
          <button
            className={`btn ${status?.load_running ? 'btn-danger' : 'btn-primary'}`}
            onClick={handleLoad}>
            {status?.load_running ? 'Stop load generator' : 'Start load generator'}
          </button>
        </section>

        {/* scaling log */}
        <section className="card span2">
          <h2>Scaling log</h2>
          <div className="log" ref={logsRef}>
            {logs.length === 0
              ? <span className="muted">no events yet</span>
              : logs.map((l, i) => <div key={i} className="log-line">{l}</div>)
            }
          </div>
        </section>

      </main>

      <footer className="footer">
  Marta Fraioli · MSc Computer Science · Trinity College Dublin · 2026 ·{' '}
  <a href="https://github.com/martafra/5g-power-dissertation" target="_blank" rel="noreferrer">
    github.com/martafra/5g-power-dissertation
  </a>
</footer>

    </div>
  )
}

export default App
