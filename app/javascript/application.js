// Local application imports are configured in config/importmap.rb.
import "@hotwired/turbo-rails"
import "controllers"

// Delegation keeps copy controls working after page navigation.
function enableCopyButtons() {
  document.querySelectorAll("[data-copy-target]").forEach(button => { button.hidden = false })
}
document.addEventListener("turbo:load", enableCopyButtons)
if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", enableCopyButtons)
else enableCopyButtons()

document.addEventListener("click", async event => {
  const button = event.target.closest("[data-copy-target]")
  if (!button) return
  const source = document.getElementById(button.dataset.copyTarget)
  const status = button.parentElement.querySelector(".copy-status")
  if (!source || !status) return
  try {
    await navigator.clipboard.writeText(source.textContent)
    status.textContent = "Copied to clipboard."
  } catch {
    const range = document.createRange()
    range.selectNodeContents(source)
    const selection = window.getSelection()
    selection.removeAllRanges()
    selection.addRange(range)
    source.focus()
    status.textContent = "Copy unavailable. Text selected; use your device’s copy command."
  }
})
