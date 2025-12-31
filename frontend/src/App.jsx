import { Routes, Route, Navigate } from 'react-router-dom'
import Layout from './components/Layout'
import Dashboard from './pages/Dashboard'
import Customers from './pages/Customers'
import CustomerDetail from './pages/CustomerDetail'
import Contracts from './pages/Contracts'
import ContractDetail from './pages/ContractDetail'
import ExpiredContracts from './pages/ExpiredContracts'
import Payments from './pages/Payments'
import MonthlyPayments from './pages/MonthlyPayments'
import Renewals from './pages/Renewals'
import Commissions from './pages/Commissions'
import Quotes from './pages/Quotes'
import QuoteCreate from './pages/QuoteCreate'
import QuoteDetail from './pages/QuoteDetail'
import QuotePublic from './pages/QuotePublic'
import Invoices from './pages/Invoices'
import LegalLetters from './pages/LegalLetters'
import Reports from './pages/Reports'
import Settings from './pages/Settings'
import Prospects from './pages/Prospects'
import ChurnedCustomers from './pages/ChurnedCustomers'
import AIAssistant from './pages/AIAssistant'
import AILearning from './pages/AILearning'
import DevTools from './pages/DevTools'
import DataValidation from './pages/DataValidation'
import Bookings from './pages/Bookings'
import FloorPlan from './pages/FloorPlan'
import ContractCreate from './pages/ContractCreate'
import ContractWorkspace from './pages/ContractWorkspace'
import ServicePlans from './pages/ServicePlans'
import Terminations from './pages/Terminations'
import ProcessDashboard from './pages/ProcessDashboard'
import IntegrityAlerts from './pages/IntegrityAlerts'

function App() {
  return (
    <Routes>
      {/* 公開頁面（不需登入） */}
      <Route path="/quote/:quoteNumber" element={<QuotePublic />} />

      {/* 後台管理頁面 */}
      <Route path="/" element={<Layout />}>
        <Route index element={<Navigate to="/dashboard" replace />} />
        <Route path="dashboard" element={<Dashboard />} />
        <Route path="customers" element={<Customers />} />
        <Route path="customers/churned" element={<ChurnedCustomers />} />
        <Route path="customers/:id" element={<CustomerDetail />} />
        <Route path="contracts" element={<Contracts />} />
        <Route path="contracts/new" element={<ContractCreate />} />
        <Route path="contracts/expired" element={<ExpiredContracts />} />
        <Route path="contracts/:id" element={<ContractDetail />} />
        <Route path="contracts/:id/workspace" element={<ContractWorkspace />} />
        <Route path="payments/legal-letters" element={<LegalLetters />} />
        <Route path="payments" element={<Payments />} />
        <Route path="payments/monthly" element={<MonthlyPayments />} />
        <Route path="invoices" element={<Invoices />} />
        <Route path="renewals" element={<Renewals />} />
        <Route path="terminations" element={<Terminations />} />
        <Route path="process-dashboard" element={<ProcessDashboard />} />
        <Route path="commissions" element={<Commissions />} />
        <Route path="reports" element={<Reports />} />
        <Route path="quotes" element={<Quotes />} />
        <Route path="quotes/new" element={<QuoteCreate />} />
        <Route path="quotes/:id" element={<QuoteDetail />} />
        <Route path="prospects" element={<Prospects />} />
        <Route path="ai-assistant" element={<AIAssistant />} />
        <Route path="ai-learning" element={<AILearning />} />
        <Route path="dev-tools" element={<DevTools />} />
        <Route path="data-validation" element={<DataValidation />} />
        <Route path="admin/integrity" element={<IntegrityAlerts />} />
        <Route path="bookings" element={<Bookings />} />
        <Route path="floor-plan" element={<FloorPlan />} />
        <Route path="settings" element={<Settings />} />
        <Route path="settings/service-plans" element={<ServicePlans />} />
      </Route>
    </Routes>
  )
}

export default App
