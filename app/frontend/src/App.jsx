import { useState, useEffect } from 'react';

const API_BASE = process.env.REACT_APP_API_URL || '';

function App() {
  const [products, setProducts]     = useState([]);
  const [loading, setLoading]       = useState(true);
  const [error, setError]           = useState(null);
  const [newProduct, setNewProduct] = useState({ name: '', description: '', price: '', stockQuantity: '' });
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => { fetchProducts(); }, []);

  const fetchProducts = async () => {
    try {
      setLoading(true);
      setError(null);
      const res = await fetch(`${API_BASE}/api/products`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      setProducts(await res.json());
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  const handleCreate = async (e) => {
    e.preventDefault();
    setSubmitting(true);
    try {
      const res = await fetch(`${API_BASE}/api/products`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          ...newProduct,
          price: parseFloat(newProduct.price),
          stockQuantity: parseInt(newProduct.stockQuantity)
        })
      });
      if (!res.ok) throw new Error('Failed to create product');
      setNewProduct({ name: '', description: '', price: '', stockQuantity: '' });
      await fetchProducts();
    } catch (err) {
      setError(err.message);
    } finally {
      setSubmitting(false);
    }
  };

  const handleDelete = async (id) => {
    if (!window.confirm('Delete this product?')) return;
    try {
      await fetch(`${API_BASE}/api/products/${id}`, { method: 'DELETE' });
      await fetchProducts();
    } catch (err) {
      setError(err.message);
    }
  };

  const inputStyle = { padding: '8px 12px', borderRadius: 4, border: '1px solid #ddd', width: '100%', fontSize: 14 };
  const btnStyle   = (color) => ({ padding: '8px 16px', background: color, color: '#fff', border: 'none', borderRadius: 4, cursor: 'pointer', fontSize: 14 });

  return (
    <div style={{ maxWidth: 900, margin: '40px auto', padding: '0 20px' }}>
      {/* Header */}
      <div style={{ marginBottom: 32 }}>
        <h1 style={{ color: '#0066cc', marginBottom: 4 }}>MNC Product Catalog</h1>
        <p style={{ color: '#666', fontSize: 13 }}>
          Environment: <strong>{process.env.REACT_APP_ENV || 'local'}</strong>
          {process.env.REACT_APP_GIT_COMMIT && (
            <> | Commit: <code style={{ fontSize: 12 }}>{process.env.REACT_APP_GIT_COMMIT}</code></>
          )}
        </p>
      </div>

      {/* Add Product Form */}
      <div style={{ background: '#f0f4ff', border: '1px solid #c5d5f5', padding: 24, borderRadius: 8, marginBottom: 32 }}>
        <h2 style={{ marginTop: 0, marginBottom: 16, fontSize: 18, color: '#333' }}>Add New Product</h2>
        <form onSubmit={handleCreate}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label style={{ display: 'block', marginBottom: 4, fontSize: 13, fontWeight: 500 }}>Name *</label>
              <input style={inputStyle} placeholder="e.g. Laptop Pro 15" required
                value={newProduct.name} onChange={e => setNewProduct({ ...newProduct, name: e.target.value })} />
            </div>
            <div>
              <label style={{ display: 'block', marginBottom: 4, fontSize: 13, fontWeight: 500 }}>Description</label>
              <input style={inputStyle} placeholder="Optional description"
                value={newProduct.description} onChange={e => setNewProduct({ ...newProduct, description: e.target.value })} />
            </div>
            <div>
              <label style={{ display: 'block', marginBottom: 4, fontSize: 13, fontWeight: 500 }}>Price (₹) *</label>
              <input style={inputStyle} type="number" step="0.01" min="0.01" placeholder="e.g. 9999.00" required
                value={newProduct.price} onChange={e => setNewProduct({ ...newProduct, price: e.target.value })} />
            </div>
            <div>
              <label style={{ display: 'block', marginBottom: 4, fontSize: 13, fontWeight: 500 }}>Stock Quantity *</label>
              <input style={inputStyle} type="number" min="0" placeholder="e.g. 100" required
                value={newProduct.stockQuantity} onChange={e => setNewProduct({ ...newProduct, stockQuantity: e.target.value })} />
            </div>
          </div>
          <button type="submit" style={btnStyle('#0066cc')} disabled={submitting}>
            {submitting ? 'Adding...' : '+ Add Product'}
          </button>
        </form>
      </div>

      {/* Error */}
      {error && (
        <div style={{ background: '#fff0f0', border: '1px solid #ffcccc', padding: '12px 16px', borderRadius: 4, marginBottom: 16, color: '#cc0000', fontSize: 14 }}>
          Error: {error} — <button onClick={fetchProducts} style={{ background: 'none', border: 'none', color: '#0066cc', cursor: 'pointer', textDecoration: 'underline', padding: 0, fontSize: 14 }}>Retry</button>
        </div>
      )}

      {/* Product Table */}
      <div style={{ background: '#fff', border: '1px solid #e0e0e0', borderRadius: 8, overflow: 'hidden' }}>
        <div style={{ padding: '16px 20px', borderBottom: '1px solid #e0e0e0', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <h2 style={{ margin: 0, fontSize: 18, color: '#333' }}>Products ({products.length})</h2>
          <button onClick={fetchProducts} style={{ ...btnStyle('#555'), padding: '6px 12px', fontSize: 13 }}>↻ Refresh</button>
        </div>
        {loading ? (
          <div style={{ padding: 40, textAlign: 'center', color: '#666' }}>Loading products...</div>
        ) : products.length === 0 ? (
          <div style={{ padding: 40, textAlign: 'center', color: '#999' }}>
            No products yet. Add one above or trigger the Jenkins pipeline to seed data.
          </div>
        ) : (
          <table style={{ width: '100%', borderCollapse: 'collapse' }}>
            <thead>
              <tr style={{ background: '#f5f5f5' }}>
                {['ID', 'Name', 'Description', 'Price', 'Stock', 'Actions'].map(h => (
                  <th key={h} style={{ padding: '12px 16px', textAlign: 'left', fontSize: 13, fontWeight: 600, color: '#555', borderBottom: '1px solid #e0e0e0' }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {products.map((p, i) => (
                <tr key={p.id} style={{ borderBottom: '1px solid #f0f0f0', background: i % 2 === 0 ? '#fff' : '#fafafa' }}>
                  <td style={{ padding: '10px 16px', fontSize: 13, color: '#888' }}>{p.id}</td>
                  <td style={{ padding: '10px 16px', fontWeight: 500 }}>{p.name}</td>
                  <td style={{ padding: '10px 16px', fontSize: 13, color: '#666' }}>{p.description || '—'}</td>
                  <td style={{ padding: '10px 16px', fontWeight: 500, color: '#0066cc' }}>₹{Number(p.price).toLocaleString('en-IN')}</td>
                  <td style={{ padding: '10px 16px', fontSize: 13 }}>
                    <span style={{ background: p.stockQuantity > 10 ? '#e6f4ea' : '#fff0f0', color: p.stockQuantity > 10 ? '#1e7e34' : '#cc0000', padding: '2px 8px', borderRadius: 12, fontSize: 12, fontWeight: 500 }}>
                      {p.stockQuantity}
                    </span>
                  </td>
                  <td style={{ padding: '10px 16px' }}>
                    <button onClick={() => handleDelete(p.id)} style={{ ...btnStyle('#dc3545'), padding: '4px 10px', fontSize: 12 }}>Delete</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}

export default App;
