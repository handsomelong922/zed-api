import { clearApiKey, fetchApiKeySettings, saveApiKey, type ApiKeySettingsStatus } from '../api'
import { icons } from '../icons'
import { showToast } from '../toast'

let currentStatus: ApiKeySettingsStatus = { enabled: false, source: 'none' }

function statusLabel(status: ApiKeySettingsStatus): string {
  if (!status.enabled) return '未启用'
  if (status.source === 'file') return '已启用 · 网页配置'
  if (status.source === 'env') return '已启用 · 环境变量后备'
  return '已启用'
}

function statusDescription(status: ApiKeySettingsStatus): string {
  if (!status.enabled) return '模型 API 当前不校验访问密钥。公网部署建议设置一把足够长的随机 Key。'
  if (status.source === 'file') return '当前使用网页保存的密钥，已持久化到 /data/settings.json，并且立即生效。修改或清除时需要输入当前 Key 验证身份。'
  return '当前使用 ZED_API_KEY 环境变量。保存网页密钥前，需要先输入当前环境变量 Key 验证身份。'
}

function updateStatus(status: ApiKeySettingsStatus) {
  currentStatus = status
  const chip = document.getElementById('api-key-status')
  const detail = document.getElementById('api-key-detail')
  const currentKeyGroup = document.getElementById('current-api-key-group') as HTMLElement | null
  const currentKeyInput = document.getElementById('current-api-key-input') as HTMLInputElement | null
  if (chip) chip.textContent = statusLabel(status)
  if (detail) detail.textContent = statusDescription(status)
  if (currentKeyGroup) currentKeyGroup.hidden = !status.enabled
  if (!status.enabled && currentKeyInput) currentKeyInput.value = ''
}

async function refreshStatus() {
  try {
    updateStatus(await fetchApiKeySettings())
  } catch (error) {
    const detail = document.getElementById('api-key-detail')
    if (detail) detail.textContent = `读取设置失败：${error instanceof Error ? error.message : '未知错误'}`
  }
}

export function renderSecurity() {
  currentStatus = { enabled: false, source: 'none' }
  const page = document.getElementById('page-security')!
  page.innerHTML = `
    <div class="page-heading">
      <div>
        <span class="eyebrow">访问控制</span>
        <h1>API Key 设置</h1>
        <p>直接在网页中设置一把全局访问密钥。保存后立即生效，重建容器时只要保留 /data 就不会丢失。</p>
      </div>
    </div>

    <div class="notice-banner neutral">
      <span>${icons.shield}</span>
      <p>密钥只保存在服务器端，不会从设置接口回显，也不会写入浏览器本地存储。OpenAI 客户端使用 <code>Authorization: Bearer &lt;key&gt;</code>，Anthropic 客户端也支持 <code>x-api-key</code>。</p>
    </div>

    <div class="integration-grid">
      <article class="integration-card featured">
        <header>
          <span class="integration-icon">${icons.shield}</span>
          <div><span>全局模型 API 鉴权</span><strong>API Key</strong></div>
          <span class="recommended-badge" id="api-key-status">读取中…</span>
        </header>
        <div class="integration-body">
          <p id="api-key-detail">正在读取当前设置。</p>

          <div id="current-api-key-group" hidden>
            <label for="current-api-key-input" style="display:block;font-weight:700;margin:18px 0 8px">当前 API Key（验证身份）</label>
            <input id="current-api-key-input" type="password" autocomplete="current-password" spellcheck="false"
              placeholder="请输入当前正在使用的 API Key"
              style="width:100%;box-sizing:border-box;padding:11px 12px;border:1px solid #b8c5d5;border-radius:9px;font:13px/1.4 ui-monospace,SFMono-Regular,Consolas,monospace" />
            <p style="margin-top:9px">已有 Key 时，修改或清除配置必须先验证当前 Key。该输入只用于本次请求，不会保存在浏览器。</p>
          </div>

          <label for="api-key-input" style="display:block;font-weight:700;margin:18px 0 8px">输入新的 API Key</label>
          <div style="display:flex;gap:9px;align-items:stretch;flex-wrap:wrap">
            <input id="api-key-input" type="password" autocomplete="new-password" spellcheck="false"
              placeholder="例如：sk-zed-xxxxxxxxxxxxxxxx"
              style="min-width:280px;flex:1;box-sizing:border-box;padding:11px 12px;border:1px solid #b8c5d5;border-radius:9px;font:13px/1.4 ui-monospace,SFMono-Regular,Consolas,monospace" />
            <button class="button secondary" id="toggle-api-key" type="button">显示</button>
          </div>
          <p style="margin-top:9px">保存成功后输入框会立即清空；出于安全原因，服务器不会把现有密钥重新显示出来。</p>
          <div style="display:flex;flex-wrap:wrap;gap:9px;margin-top:18px">
            <button class="button primary" id="save-api-key" type="button">保存 API Key</button>
            <button class="button secondary" id="clear-api-key" type="button">清除 API Key</button>
          </div>
        </div>
      </article>
    </div>
  `

  const input = document.getElementById('api-key-input') as HTMLInputElement
  const currentKeyInput = document.getElementById('current-api-key-input') as HTMLInputElement
  const toggle = document.getElementById('toggle-api-key') as HTMLButtonElement
  const save = document.getElementById('save-api-key') as HTMLButtonElement
  const clear = document.getElementById('clear-api-key') as HTMLButtonElement

  toggle.addEventListener('click', () => {
    const visible = input.type === 'text'
    input.type = visible ? 'password' : 'text'
    toggle.textContent = visible ? '显示' : '隐藏'
  })

  save.addEventListener('click', async () => {
    const value = input.value.trim()
    if (!value) {
      showToast('请输入要保存的 API Key')
      input.focus()
      return
    }
    const currentKey = currentKeyInput.value.trim()
    if (currentStatus.enabled && !currentKey) {
      showToast('请输入当前 API Key 以验证身份')
      currentKeyInput.focus()
      return
    }

    save.disabled = true
    try {
      const status = await saveApiKey(value, currentStatus.enabled ? currentKey : undefined)
      input.value = ''
      currentKeyInput.value = ''
      input.type = 'password'
      toggle.textContent = '显示'
      updateStatus(status)
      showToast('API Key 已保存并立即生效')
    } catch (error) {
      showToast(`保存失败：${error instanceof Error ? error.message : '未知错误'}`)
    } finally {
      save.disabled = false
    }
  })

  clear.addEventListener('click', async () => {
    const currentKey = currentKeyInput.value.trim()
    if (currentStatus.enabled && !currentKey) {
      showToast('请输入当前 API Key 以验证身份')
      currentKeyInput.focus()
      return
    }

    clear.disabled = true
    try {
      const status = await clearApiKey(currentStatus.enabled ? currentKey : undefined)
      currentKeyInput.value = ''
      updateStatus(status)
      showToast(status.source === 'env' ? '网页密钥已清除，已回退到环境变量' : 'API Key 已清除')
    } catch (error) {
      showToast(`清除失败：${error instanceof Error ? error.message : '未知错误'}`)
    } finally {
      clear.disabled = false
    }
  })

  void refreshStatus()
}
