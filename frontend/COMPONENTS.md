# 前端組件使用規範

> 本文件定義專案內共用組件的 API 規範，確保一致性並避免錯誤使用。

---

## DataTable 表格組件

### 基本用法

```jsx
import DataTable from '../components/DataTable'

const columns = [
  {
    accessor: 'id',
    header: '#',
    cell: (row) => <span>#{row.id}</span>
  },
  {
    accessor: 'name',
    header: '名稱',
    cell: (row) => <span className="font-medium">{row.name}</span>
  },
  {
    header: '操作',
    sortable: false,
    cell: (row) => (
      <button onClick={() => handleEdit(row)}>編輯</button>
    )
  }
]

<DataTable
  columns={columns}
  data={data}
  loading={isLoading}
/>
```

### Column 定義

| 屬性 | 類型 | 必填 | 說明 |
|------|------|------|------|
| `header` | `string` | ✅ | 表頭標題 |
| `accessor` | `string` | ❌ | 資料欄位名稱（用於取值和排序） |
| `cell` | `(row, index) => ReactNode` | ❌ | 自定義渲染函數 |
| `sortable` | `boolean` | ❌ | 是否可排序（預設 `true`） |
| `width` | `string` | ❌ | 欄位寬度（如 `'100px'`） |
| `className` | `string` | ❌ | 額外 CSS class |

### Props

| 屬性 | 類型 | 預設值 | 說明 |
|------|------|--------|------|
| `columns` | `Column[]` | - | 欄位定義（必填） |
| `data` | `object[]` | `[]` | 資料陣列 |
| `loading` | `boolean` | `false` | 載入中狀態 |
| `searchable` | `boolean` | `true` | 是否顯示搜尋框 |
| `exportable` | `boolean` | `true` | 是否顯示匯出按鈕 |
| `pagination` | `boolean` | `true` | 是否啟用分頁 |
| `pageSize` | `number` | `10` | 每頁筆數 |
| `onRefresh` | `() => void` | - | 重新整理回調 |
| `onRowClick` | `(row) => void` | - | 列點擊回調 |
| `emptyMessage` | `string` | `'沒有資料'` | 空資料訊息 |
| `actions` | `ReactNode` | - | 額外操作按鈕 |
| `id` | `string` | - | 表格 ID |

### ⚠️ 常見錯誤

#### ❌ 錯誤：使用 `key/label/render`

```jsx
// 這是錯誤的！
const columns = [
  {
    key: 'name',           // ❌ 應為 accessor
    label: '名稱',         // ❌ 應為 header
    render: (value) => ... // ❌ 應為 cell，且簽名不同
  }
]
```

#### ✅ 正確：使用 `accessor/header/cell`

```jsx
// 這是正確的！
const columns = [
  {
    accessor: 'name',
    header: '名稱',
    cell: (row) => <span>{row.name}</span>
  }
]
```

#### 函數簽名差異

```jsx
// ❌ 錯誤的 render 簽名（舊格式）
render: (value, row) => <span>{value}</span>

// ✅ 正確的 cell 簽名
cell: (row, index) => <span>{row.name}</span>
```

### 開發環境警告

DataTable 組件會在**開發環境**自動檢測並警告錯誤的屬性名稱：

```
[DataTable] columns[0] 使用了 "key" 屬性，應改為 "accessor"。
正確格式：{ accessor: 'name', header: '...', cell: (row) => ... }
```

---

## Modal 對話框組件

### 基本用法

```jsx
import Modal from '../components/Modal'

<Modal
  open={isOpen}
  onClose={() => setIsOpen(false)}
  title="標題"
  size="md"
>
  <div>內容</div>
</Modal>
```

### Props

| 屬性 | 類型 | 預設值 | 說明 |
|------|------|--------|------|
| `open` | `boolean` | - | 是否開啟（必填） |
| `onClose` | `() => void` | - | 關閉回調（必填） |
| `title` | `string` | - | 標題 |
| `size` | `'sm' \| 'md' \| 'lg' \| 'xl'` | `'md'` | 尺寸 |
| `footer` | `ReactNode \| null` | - | 底部內容，設為 `null` 隱藏 |
| `children` | `ReactNode` | - | 內容 |

---

## 狀態管理 Hook

### useModal

統一管理 Modal 狀態的 Hook。

```jsx
import { useModal, usePaymentModals } from '../hooks/useModal'

// 基礎用法
const modal = useModal()
modal.open('edit', { id: 123 })
modal.isOpen('edit')  // true
modal.getData()       // { id: 123 }
modal.close()

// 付款頁面專用
const modal = usePaymentModals()
modal.openPay(payment)
modal.openWaive(payment)
modal.isPayOpen  // true/false
```

---

## 命名規範

### 文件命名

| 類型 | 規範 | 範例 |
|------|------|------|
| 組件 | PascalCase | `DataTable.jsx`, `PaymentModal.jsx` |
| Hook | camelCase + `use` 前綴 | `useModal.js`, `useStore.js` |
| 頁面 | PascalCase | `Payments.jsx`, `Contracts.jsx` |
| 服務 | camelCase | `api.js`, `utils.js` |

### Props 命名

| 類型 | 規範 | 範例 |
|------|------|------|
| 事件處理 | `on` + 動詞 | `onClick`, `onSubmit`, `onClose` |
| 布林值 | `is/has/show/can` + 名詞 | `isOpen`, `hasError`, `showModal` |
| 資料 | 名詞 | `data`, `columns`, `items` |

---

## 最佳實踐

### 1. 永遠使用 TypeScript 或 PropTypes

確保 props 類型正確，避免運行時錯誤。

### 2. 組件保持單一職責

一個組件只做一件事，複雜邏輯抽取到 Hook。

### 3. 參考現有實作

新增頁面時，參考專案內已有頁面的實作方式（如 `Payments.jsx`）。

### 4. 測試開發環境警告

開發時注意 console 的警告訊息，它們能幫助發現錯誤。
