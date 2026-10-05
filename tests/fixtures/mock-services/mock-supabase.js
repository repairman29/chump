// Vendored from repairman29/mock-services at commit 8ce1577686a23b0b51391d6926cdf846e5a23c3f,
// original path mock-supabase.js, brought in via CP-009 (INFRA-1841).
const express = require('express');
const cors = require('cors');

const app = express();
const PORT = process.env.MOCK_PORT || 4012;

// Middleware
app.use(cors());
app.use(express.json());

// Mock database storage
let mockData = {
    users: [],
    sessions: [],
    characters: [],
    games: []
};

// Mock responses for Supabase-like endpoints
app.post('/auth/v1/signup', (req, res) => {
    console.log('📨 Mock Supabase: Signup request');
    const { email, password } = req.body;

    const user = {
        id: `user_${Date.now()}`,
        email: email,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString()
    };

    mockData.users.push(user);

    res.json({
        access_token: 'mock_access_token_123',
        token_type: 'bearer',
        expires_in: 3600,
        refresh_token: 'mock_refresh_token_456',
        user: user
    });
});

app.post('/auth/v1/signin', (req, res) => {
    console.log('📨 Mock Supabase: Signin request');
    const { email, password } = req.body;

    const user = mockData.users.find(u => u.email === email);

    if (user) {
        res.json({
            access_token: 'mock_access_token_123',
            token_type: 'bearer',
            expires_in: 3600,
            refresh_token: 'mock_refresh_token_456',
            user: user
        });
    } else {
        res.status(400).json({
            error: 'Invalid credentials',
            message: 'User not found in mock database'
        });
    }
});

app.get('/rest/v1/:table', (req, res) => {
    const { table } = req.params;
    console.log(`📨 Mock Supabase: GET /${table}`);

    const data = mockData[table] || [];
    res.json(data);
});

app.post('/rest/v1/:table', (req, res) => {
    const { table } = req.params;
    console.log(`📨 Mock Supabase: POST /${table}`, req.body);

    if (!mockData[table]) {
        mockData[table] = [];
    }

    const newItem = {
        id: `item_${Date.now()}`,
        ...req.body,
        created_at: new Date().toISOString()
    };

    mockData[table].push(newItem);
    res.json(newItem);
});

// Health check
app.get('/health', (req, res) => {
    res.json({
        status: 'healthy',
        service: 'mock-supabase',
        version: '1.0.0',
        timestamp: new Date().toISOString(),
        data_counts: Object.fromEntries(
            Object.entries(mockData).map(([table, items]) => [table, items.length])
        )
    });
});

// Root endpoint
app.get('/', (req, res) => {
    res.json({
        message: '🗄️ Smugglers Mock Supabase Service',
        endpoints: [
            'POST /auth/v1/signup',
            'POST /auth/v1/signin',
            'GET /rest/v1/:table',
            'POST /rest/v1/:table'
        ],
        note: 'This is a development mock service. Data is stored in memory only.'
    });
});

// Error handling
app.use((err, req, res, next) => {
    console.error('Mock Supabase Error:', err);
    res.status(500).json({
        error: {
            message: 'Internal mock service error',
            type: 'mock_error'
        }
    });
});

// Start server
app.listen(PORT, () => {
    console.log(`🗄️ Mock Supabase Service running on port ${PORT}`);
    console.log(`📊 Health check: http://localhost:${PORT}/health`);
    console.log(`🔗 Mock endpoints: http://localhost:${PORT}/auth/v1/*`);
});
