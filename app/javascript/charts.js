import Chart from "chart.js/auto"

function palette() {
  const styles = getComputedStyle(document.documentElement)
  const token = (name, fallback) => styles.getPropertyValue(name).trim() || fallback

  return {
    text: token("--chart-text", "#666"),
    grid: token("--chart-grid", "rgba(0, 0, 0, 0.05)"),
    border: token("--chart-border", "rgba(0, 0, 0, 0.1)")
  }
}

function applyDefaults({ text, grid, border }) {
  Chart.defaults.color = text
  Chart.defaults.borderColor = border
  Chart.defaults.scale.grid.color = grid
}

function restyle(chart, { text, grid, border }) {
  Object.values(chart.options.scales || {}).forEach(scale => {
    if (scale.ticks) scale.ticks.color = text
    if (scale.title) scale.title.color = text
    if (scale.grid) scale.grid.color = grid
    if (scale.border) scale.border.color = border
  })

  const legendLabels = chart.options.plugins?.legend?.labels
  if (legendLabels) legendLabels.color = text

  chart.update("none")
}

applyDefaults(palette())

document.addEventListener("theme:change", () => {
  const colors = palette()
  applyDefaults(colors)
  Object.values(Chart.instances).forEach(chart => restyle(chart, colors))
})

export default Chart
