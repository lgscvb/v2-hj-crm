import { useState } from 'react'
import {
  LayoutDashboard,
  FileText,
  Bell,
  CreditCard,
  Receipt,
  Users,
  ChevronDown,
  ChevronRight,
  HelpCircle,
  Lightbulb,
  ArrowRight,
  CheckCircle2,
  AlertCircle,
  ExternalLink,
  BookOpen,
  Wrench,
  Server,
  Database,
  RefreshCw,
  Terminal,
  Shield,
  Globe,
  Copy,
  Check
} from 'lucide-react'

// 教學章節資料
const sections = [
  {
    id: 'workflow',
    title: '核心工作流程',
    icon: ArrowRight,
    content: null,
  },
  {
    id: 'dashboard',
    title: 'Dashboard 首頁',
    icon: LayoutDashboard,
    description: '登入後第一個看到的頁面，讓您快速了解今天需要處理什麼。',
    features: [
      { title: '統計卡片', desc: '顯示待處理事項總數' },
      { title: '到期提醒', desc: '近期到期的合約' },
      { title: '逾期繳費', desc: '需要催繳的款項' },
      { title: '快速導航', desc: '點擊卡片直接跳轉' },
    ],
    tip: '每天上班第一件事：看 Dashboard 的數字，優先處理紅色警告！',
    link: '/dashboard'
  },
  {
    id: 'contracts',
    title: '合約管理',
    icon: FileText,
    description: '這裡可以查看、搜尋、新增所有合約資料。',
    features: [
      { title: '狀態篩選', desc: '依狀態快速過濾（生效中/已到期/已續約）' },
      { title: '搜尋功能', desc: '輸入公司名稱或合約編號' },
      { title: '新增合約', desc: '右上角「新增」按鈕' },
      { title: '合約詳情', desc: '點擊任一筆查看完整資料' },
    ],
    tip: '點擊「新增」→ 填寫客戶與合約資料 → 儲存後系統自動產生繳費記錄',
    link: '/contracts'
  },
  {
    id: 'renewals',
    title: '續約管理',
    icon: Bell,
    description: '這裡顯示所有即將到期的合約，方便您提前處理續約事宜。',
    features: [
      { title: '急件標籤', desc: '7 天內到期的合約優先處理' },
      { title: '進度追蹤', desc: '待處理/進行中/已完成' },
      { title: '建立續約', desc: '一鍵帶入舊合約資料' },
      { title: '已移交切換', desc: '隱藏/顯示已完成交接的項目' },
    ],
    tip: '建議在合約到期前 30 天開始聯繫客戶，系統會自動提醒！',
    link: '/renewals'
  },
  {
    id: 'payments',
    title: '繳費管理',
    icon: CreditCard,
    description: '追蹤每筆款項的繳費狀態，處理催繳與收款記錄。',
    features: [
      { title: '狀態篩選', desc: '待繳/已繳/逾期/已免收' },
      { title: '記錄繳費', desc: '選擇付款方式、填入金額' },
      { title: '發送催繳', desc: '一鍵發送 LINE 催繳通知' },
      { title: '申請免收', desc: '特殊情況可申請免除款項' },
    ],
    tip: '逾期款項會以紅色標示，建議優先處理超過 30 天的項目。',
    link: '/payments'
  },
  {
    id: 'invoices',
    title: '發票管理',
    icon: Receipt,
    description: '處理所有發票的開立、作廢與折讓。',
    features: [
      { title: '開立發票', desc: '填入發票號碼與相關資訊' },
      { title: '作廢發票', desc: '輸入作廢原因即可' },
      { title: '折讓處理', desc: '部分退款時使用' },
      { title: '發票查詢', desc: '依日期、狀態、客戶搜尋' },
    ],
    tip: '發票一經開立無法修改，請確認資料正確後再開立！',
    link: '/invoices'
  },
  {
    id: 'customers',
    title: '客戶管理',
    icon: Users,
    description: '維護所有客戶的基本資料與聯絡資訊。',
    features: [
      { title: '客戶列表', desc: '查看所有客戶' },
      { title: '搜尋功能', desc: '依公司名或聯絡人搜尋' },
      { title: '編輯資料', desc: '更新聯絡資訊' },
      { title: '合約連結', desc: '查看客戶的所有合約' },
    ],
    tip: '客戶資料會自動帶入新合約，請保持資料正確！',
    link: '/customers'
  },
]

// FAQ 資料
const faqs = [
  { q: '看不到資料怎麼辦？', a: '請先重新整理頁面（按 F5 或 Cmd+R）。如果還是沒有資料，請確認網路連線，或聯繫系統管理員。' },
  { q: '如何處理續約合約？', a: '進入「續約」頁面 → 找到要續約的合約 → 點擊「建立續約合約」→ 系統會自動帶入舊合約資料 → 修改新條款後儲存即可。' },
  { q: '記錄繳費後可以撤銷嗎？', a: '可以！在繳費頁面找到該筆款項，點擊「撤銷付款」並輸入原因即可。但如果已經開立發票，需要先作廢發票。' },
  { q: '發票開錯怎麼辦？', a: '在發票頁面找到該張發票，點擊「作廢」並輸入作廢原因。作廢後可以重新開立正確的發票。' },
  { q: '如何發送 LINE 催繳通知？', a: '在繳費頁面找到逾期款項，點擊「發送催繳」按鈕，系統會自動透過 LINE 發送催繳訊息給客戶。' },
  { q: '「急件」是什麼意思？', a: '「急件」表示合約將在 7 天內到期，需要優先處理。在續約頁面點擊「急件」按鈕可以快速篩選這些項目。' },
]

// 維運指令
const opsCommands = {
  deploy: 'make deploy-backend',
  restart: 'cd ~/v2-hj-crm/backend && docker-compose restart mcp-server',
  restartAll: 'cd ~/v2-hj-crm/backend && docker-compose down && docker-compose up -d',
  logs: 'docker logs --tail 100 hj-mcp-server',
  logsFollow: 'docker logs -f hj-mcp-server',
  migration: 'docker exec -i hj-postgres psql -U hjadmin -d hourjungle < ~/v2-hj-crm/backend/sql/migrations/XXX.sql',
  reloadSchema: 'docker exec hj-postgres psql -U hjadmin -d hourjungle -c "NOTIFY pgrst, \'reload schema\';"',
  backup: 'docker exec -i hj-postgres pg_dump -U hjadmin -d hourjungle > /tmp/hj_backup_$(date +%Y%m%d).sql',
  ssh: 'gcloud compute ssh hj-crm-vm --zone=us-west1-a --project=hj-crm-482012',
}

// 複製按鈕元件
function CopyButton({ text }) {
  const [copied, setCopied] = useState(false)

  const handleCopy = async () => {
    await navigator.clipboard.writeText(text)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  return (
    <button
      onClick={handleCopy}
      className="p-1.5 text-gray-400 hover:text-gray-600 hover:bg-gray-100 rounded transition-colors"
      title="複製"
    >
      {copied ? <Check className="w-4 h-4 text-green-500" /> : <Copy className="w-4 h-4" />}
    </button>
  )
}

// 指令區塊元件
function CommandBlock({ command, description }) {
  return (
    <div className="bg-gray-900 rounded-lg overflow-hidden">
      {description && (
        <div className="px-4 py-2 bg-gray-800 text-gray-400 text-sm border-b border-gray-700">
          {description}
        </div>
      )}
      <div className="flex items-center justify-between px-4 py-3">
        <code className="text-green-400 text-sm font-mono">{command}</code>
        <CopyButton text={command} />
      </div>
    </div>
  )
}

export default function Tutorial() {
  const [activeTab, setActiveTab] = useState('guide') // guide | ops
  const [expandedSection, setExpandedSection] = useState('workflow')
  const [expandedFaq, setExpandedFaq] = useState(null)

  return (
    <div className="max-w-5xl mx-auto space-y-6">
      {/* Header */}
      <div className="text-center py-6">
        <div className="inline-flex items-center justify-center w-16 h-16 bg-gradient-to-br from-jungle-500 to-jungle-600 rounded-2xl mb-4">
          <HelpCircle className="w-8 h-8 text-white" />
        </div>
        <h1 className="text-3xl font-bold text-gray-900">系統說明文件</h1>
        <p className="text-gray-500 mt-2">使用教學與維運指南</p>
      </div>

      {/* Tab Switcher */}
      <div className="bg-white rounded-2xl shadow-sm border border-gray-100 p-2">
        <div className="flex gap-2">
          <button
            onClick={() => setActiveTab('guide')}
            className={`flex-1 flex items-center justify-center gap-2 px-4 py-3 rounded-xl font-medium transition-all ${
              activeTab === 'guide'
                ? 'bg-jungle-600 text-white'
                : 'text-gray-600 hover:bg-gray-100'
            }`}
          >
            <BookOpen className="w-5 h-5" />
            <span>使用教學</span>
          </button>
          <button
            onClick={() => setActiveTab('ops')}
            className={`flex-1 flex items-center justify-center gap-2 px-4 py-3 rounded-xl font-medium transition-all ${
              activeTab === 'ops'
                ? 'bg-jungle-600 text-white'
                : 'text-gray-600 hover:bg-gray-100'
            }`}
          >
            <Wrench className="w-5 h-5" />
            <span>維運文件</span>
          </button>
        </div>
      </div>

      {/* ========== 使用教學 Tab ========== */}
      {activeTab === 'guide' && (
        <>
          {/* Quick Nav */}
          <div className="bg-white rounded-2xl shadow-sm border border-gray-100 p-6">
            <h2 className="text-lg font-semibold text-gray-900 mb-4">快速導覽</h2>
            <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-3">
              {sections.map((section) => (
                <button
                  key={section.id}
                  onClick={() => setExpandedSection(section.id)}
                  className={`flex items-center gap-3 p-3 rounded-xl transition-all text-left ${
                    expandedSection === section.id
                      ? 'bg-jungle-50 text-jungle-700 ring-2 ring-jungle-500'
                      : 'bg-gray-50 text-gray-700 hover:bg-gray-100'
                  }`}
                >
                  <section.icon className="w-5 h-5" />
                  <span className="font-medium text-sm">{section.title}</span>
                </button>
              ))}
              <button
                onClick={() => setExpandedSection('faq')}
                className={`flex items-center gap-3 p-3 rounded-xl transition-all text-left ${
                  expandedSection === 'faq'
                    ? 'bg-jungle-50 text-jungle-700 ring-2 ring-jungle-500'
                    : 'bg-gray-50 text-gray-700 hover:bg-gray-100'
                }`}
              >
                <AlertCircle className="w-5 h-5" />
                <span className="font-medium text-sm">常見問題</span>
              </button>
            </div>
          </div>

          {/* Workflow Section */}
          {expandedSection === 'workflow' && (
            <div className="bg-white rounded-2xl shadow-sm border border-gray-100 p-6">
              <h2 className="text-xl font-bold text-gray-900 mb-4">核心工作流程</h2>
              <p className="text-gray-600 mb-6">記住這個流程，就能處理 90% 的日常工作：</p>
              <div className="flex flex-wrap items-center justify-center gap-4 py-8 bg-gradient-to-r from-gray-50 to-gray-100 rounded-xl">
                <div className="flex items-center gap-2 bg-white px-5 py-3 rounded-xl shadow-sm">
                  <FileText className="w-5 h-5 text-jungle-600" />
                  <span className="font-semibold">合約</span>
                </div>
                <ArrowRight className="w-6 h-6 text-jungle-500" />
                <div className="flex items-center gap-2 bg-white px-5 py-3 rounded-xl shadow-sm">
                  <Bell className="w-5 h-5 text-jungle-600" />
                  <span className="font-semibold">續約</span>
                </div>
                <ArrowRight className="w-6 h-6 text-jungle-500" />
                <div className="flex items-center gap-2 bg-white px-5 py-3 rounded-xl shadow-sm">
                  <CreditCard className="w-5 h-5 text-jungle-600" />
                  <span className="font-semibold">繳費</span>
                </div>
                <ArrowRight className="w-6 h-6 text-jungle-500" />
                <div className="flex items-center gap-2 bg-white px-5 py-3 rounded-xl shadow-sm">
                  <Receipt className="w-5 h-5 text-jungle-600" />
                  <span className="font-semibold">發票</span>
                </div>
              </div>
              <div className="mt-6 p-4 bg-amber-50 rounded-xl border border-amber-200">
                <div className="flex items-start gap-3">
                  <Lightbulb className="w-5 h-5 text-amber-600 mt-0.5" />
                  <div>
                    <p className="font-medium text-amber-800">一句話記住</p>
                    <p className="text-amber-700 text-sm mt-1">
                      有問題就回到「合約 → 續約 → 繳費 → 發票」這條主線做就對了。
                    </p>
                  </div>
                </div>
              </div>
            </div>
          )}

          {/* Content Sections */}
          {sections.filter(s => s.id !== 'workflow').map((section) => (
            expandedSection === section.id && (
              <div key={section.id} className="bg-white rounded-2xl shadow-sm border border-gray-100 overflow-hidden">
                <div className="p-6 border-b border-gray-100">
                  <div className="flex items-center gap-4">
                    <div className="w-12 h-12 bg-jungle-100 rounded-xl flex items-center justify-center">
                      <section.icon className="w-6 h-6 text-jungle-600" />
                    </div>
                    <div className="flex-1">
                      <h2 className="text-xl font-bold text-gray-900">{section.title}</h2>
                      <p className="text-gray-500 mt-1">{section.description}</p>
                    </div>
                    {section.link && (
                      <a href={section.link} className="flex items-center gap-2 px-4 py-2 bg-jungle-600 text-white rounded-lg hover:bg-jungle-700 transition-colors">
                        <span>前往頁面</span>
                        <ExternalLink className="w-4 h-4" />
                      </a>
                    )}
                  </div>
                </div>
                <div className="p-6">
                  <h3 className="text-sm font-semibold text-gray-500 uppercase tracking-wider mb-4">功能說明</h3>
                  <div className="grid sm:grid-cols-2 gap-4">
                    {section.features.map((feature, idx) => (
                      <div key={idx} className="flex items-start gap-3 p-4 bg-gray-50 rounded-xl">
                        <CheckCircle2 className="w-5 h-5 text-green-500 mt-0.5" />
                        <div>
                          <p className="font-medium text-gray-900">{feature.title}</p>
                          <p className="text-sm text-gray-500 mt-0.5">{feature.desc}</p>
                        </div>
                      </div>
                    ))}
                  </div>
                  {section.tip && (
                    <div className="mt-6 p-4 bg-amber-50 rounded-xl border border-amber-200">
                      <div className="flex items-start gap-3">
                        <Lightbulb className="w-5 h-5 text-amber-600 mt-0.5" />
                        <div>
                          <p className="font-medium text-amber-800">小技巧</p>
                          <p className="text-amber-700 text-sm mt-1">{section.tip}</p>
                        </div>
                      </div>
                    </div>
                  )}
                </div>
              </div>
            )
          ))}

          {/* FAQ Section */}
          {expandedSection === 'faq' && (
            <div className="bg-white rounded-2xl shadow-sm border border-gray-100 p-6">
              <h2 className="text-xl font-bold text-gray-900 mb-6">常見問題 FAQ</h2>
              <div className="space-y-3">
                {faqs.map((faq, idx) => (
                  <div key={idx} className="border border-gray-200 rounded-xl overflow-hidden">
                    <button
                      onClick={() => setExpandedFaq(expandedFaq === idx ? null : idx)}
                      className="w-full flex items-center justify-between p-4 text-left bg-gray-50 hover:bg-gray-100 transition-colors"
                    >
                      <span className="font-medium text-gray-900">Q：{faq.q}</span>
                      {expandedFaq === idx ? <ChevronDown className="w-5 h-5 text-gray-500" /> : <ChevronRight className="w-5 h-5 text-gray-500" />}
                    </button>
                    {expandedFaq === idx && (
                      <div className="p-4 bg-white border-t border-gray-200">
                        <p className="text-gray-600 leading-relaxed">{faq.a}</p>
                      </div>
                    )}
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Status Guide */}
          <div className="bg-white rounded-2xl shadow-sm border border-gray-100 p-6">
            <h2 className="text-lg font-semibold text-gray-900 mb-4">狀態說明</h2>
            <div className="grid sm:grid-cols-3 gap-4">
              <div className="flex items-center gap-3 p-4 bg-green-50 rounded-xl">
                <span className="w-3 h-3 bg-green-500 rounded-full"></span>
                <div>
                  <p className="font-medium text-green-700">生效中 / 已繳費</p>
                  <p className="text-sm text-green-600">正常狀態</p>
                </div>
              </div>
              <div className="flex items-center gap-3 p-4 bg-yellow-50 rounded-xl">
                <span className="w-3 h-3 bg-yellow-500 rounded-full"></span>
                <div>
                  <p className="font-medium text-yellow-700">即將到期 / 待繳費</p>
                  <p className="text-sm text-yellow-600">需要注意</p>
                </div>
              </div>
              <div className="flex items-center gap-3 p-4 bg-red-50 rounded-xl">
                <span className="w-3 h-3 bg-red-500 rounded-full"></span>
                <div>
                  <p className="font-medium text-red-700">已到期 / 逾期</p>
                  <p className="text-sm text-red-600">需要處理</p>
                </div>
              </div>
            </div>
          </div>
        </>
      )}

      {/* ========== 維運文件 Tab ========== */}
      {activeTab === 'ops' && (
        <>
          {/* 重要網址 */}
          <div className="bg-white rounded-2xl shadow-sm border border-gray-100 p-6">
            <div className="flex items-center gap-3 mb-4">
              <Globe className="w-6 h-6 text-jungle-600" />
              <h2 className="text-lg font-semibold text-gray-900">重要網址</h2>
            </div>
            <div className="space-y-3">
              <div className="flex items-center justify-between p-4 bg-green-50 rounded-xl">
                <div>
                  <p className="font-medium text-green-800">前端（給人用）</p>
                  <a href="https://hj-v2.yourspce.org" target="_blank" rel="noopener noreferrer" className="text-green-600 hover:underline">
                    https://hj-v2.yourspce.org
                  </a>
                </div>
                <CopyButton text="https://hj-v2.yourspce.org" />
              </div>
              <div className="flex items-center justify-between p-4 bg-blue-50 rounded-xl">
                <div>
                  <p className="font-medium text-blue-800">後端 API</p>
                  <a href="https://api-v2.yourspce.org" target="_blank" rel="noopener noreferrer" className="text-blue-600 hover:underline">
                    https://api-v2.yourspce.org
                  </a>
                </div>
                <CopyButton text="https://api-v2.yourspce.org" />
              </div>
              <div className="flex items-center justify-between p-4 bg-red-50 rounded-xl">
                <div>
                  <p className="font-medium text-red-800">不要用（可能有舊快取）</p>
                  <span className="text-red-600 line-through">https://hj-v2.pages.dev</span>
                </div>
              </div>
            </div>
          </div>

          {/* 部署 */}
          <div className="bg-white rounded-2xl shadow-sm border border-gray-100 p-6">
            <div className="flex items-center gap-3 mb-4">
              <Server className="w-6 h-6 text-jungle-600" />
              <h2 className="text-lg font-semibold text-gray-900">部署</h2>
            </div>
            <div className="space-y-4">
              <div>
                <h3 className="font-medium text-gray-700 mb-2">後端部署</h3>
                <CommandBlock command={opsCommands.deploy} description="在專案根目錄執行" />
              </div>
              <div>
                <h3 className="font-medium text-gray-700 mb-2">前端部署</h3>
                <div className="p-4 bg-gray-50 rounded-xl text-gray-600">
                  只要 push 到 main 分支，Cloudflare Pages 會自動部署。
                </div>
              </div>
            </div>
          </div>

          {/* 重啟服務 */}
          <div className="bg-white rounded-2xl shadow-sm border border-gray-100 p-6">
            <div className="flex items-center gap-3 mb-4">
              <RefreshCw className="w-6 h-6 text-jungle-600" />
              <h2 className="text-lg font-semibold text-gray-900">重啟服務（網站壞掉時）</h2>
            </div>
            <div className="space-y-4">
              <CommandBlock command={opsCommands.ssh} description="1. 先 SSH 進 VM" />
              <CommandBlock command={opsCommands.restart} description="2. 重啟 MCP Server" />
              <div className="p-4 bg-amber-50 rounded-xl border border-amber-200">
                <p className="text-amber-800 text-sm">如果還是壞掉，再重啟全部：</p>
              </div>
              <CommandBlock command={opsCommands.restartAll} />
            </div>
          </div>

          {/* 查看 Log */}
          <div className="bg-white rounded-2xl shadow-sm border border-gray-100 p-6">
            <div className="flex items-center gap-3 mb-4">
              <Terminal className="w-6 h-6 text-jungle-600" />
              <h2 className="text-lg font-semibold text-gray-900">查看 Log（除錯用）</h2>
            </div>
            <div className="space-y-4">
              <CommandBlock command={opsCommands.logs} description="看最近 100 行" />
              <CommandBlock command={opsCommands.logsFollow} description="持續追蹤（Ctrl+C 停止）" />
            </div>
          </div>

          {/* 資料庫 Migration */}
          <div className="bg-white rounded-2xl shadow-sm border border-gray-100 p-6">
            <div className="flex items-center gap-3 mb-4">
              <Database className="w-6 h-6 text-jungle-600" />
              <h2 className="text-lg font-semibold text-gray-900">資料庫 Migration</h2>
            </div>
            <div className="space-y-4">
              <div className="p-4 bg-gray-50 rounded-xl text-gray-600 text-sm">
                <p>1. 在 <code className="bg-gray-200 px-1 rounded">backend/sql/migrations/</code> 新增 SQL 檔案</p>
                <p className="mt-1">2. SSH 到 VM 執行以下指令</p>
              </div>
              <CommandBlock command={opsCommands.migration} description="執行 Migration（把 XXX 換成實際檔名）" />
              <CommandBlock command={opsCommands.reloadSchema} description="重新載入 Schema（讓 API 看到新欄位）" />
            </div>
          </div>

          {/* 備份 */}
          <div className="bg-white rounded-2xl shadow-sm border border-gray-100 p-6">
            <div className="flex items-center gap-3 mb-4">
              <Shield className="w-6 h-6 text-jungle-600" />
              <h2 className="text-lg font-semibold text-gray-900">備份（重大改動前）</h2>
            </div>
            <CommandBlock command={opsCommands.backup} description="在 VM 裡執行" />
          </div>

          {/* 常見問題 */}
          <div className="bg-white rounded-2xl shadow-sm border border-gray-100 p-6">
            <h2 className="text-lg font-semibold text-gray-900 mb-4">常見問題處理</h2>
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-gray-200">
                    <th className="text-left py-3 px-4 font-medium text-gray-700">問題</th>
                    <th className="text-left py-3 px-4 font-medium text-gray-700">第一步</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-gray-100">
                  <tr>
                    <td className="py-3 px-4 text-gray-600">前端打不開</td>
                    <td className="py-3 px-4 text-gray-600">確認網址是否正確（不要用 pages.dev）</td>
                  </tr>
                  <tr>
                    <td className="py-3 px-4 text-gray-600">API 出錯</td>
                    <td className="py-3 px-4 text-gray-600">先重啟 mcp-server</td>
                  </tr>
                  <tr>
                    <td className="py-3 px-4 text-gray-600">資料欄位怪怪的</td>
                    <td className="py-3 px-4 text-gray-600">檢查最新 migration 是否已部署</td>
                  </tr>
                  <tr>
                    <td className="py-3 px-4 text-gray-600">不確定哪裡壞了</td>
                    <td className="py-3 px-4 text-gray-600">看 Log</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          {/* 交付檢查清單 */}
          <div className="bg-white rounded-2xl shadow-sm border border-gray-100 p-6">
            <h2 className="text-lg font-semibold text-gray-900 mb-4">交付檢查清單</h2>
            <div className="space-y-2">
              {[
                '前端能打開並登入',
                '合約/繳費/發票/續約頁能顯示資料',
                '最新 migration 已執行',
                '重大改動有備份'
              ].map((item, idx) => (
                <div key={idx} className="flex items-center gap-3 p-3 bg-gray-50 rounded-lg">
                  <div className="w-5 h-5 border-2 border-gray-300 rounded"></div>
                  <span className="text-gray-700">{item}</span>
                </div>
              ))}
            </div>
          </div>
        </>
      )}
    </div>
  )
}
