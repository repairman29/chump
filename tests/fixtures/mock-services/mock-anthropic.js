// Vendored from repairman29/mock-services at commit 8ce1577686a23b0b51391d6926cdf846e5a23c3f,
// original path mock-anthropic.js, brought in via CP-009 (INFRA-1841).
const express = require('express');
const cors = require('cors');

const app = express();
const PORT = process.env.MOCK_PORT || 4011;

// Middleware
app.use(cors());
app.use(express.json());

// Mock responses for different Anthropic endpoints
const mockResponses = {
    '/v1/messages': {
        id: 'msg_mock_123',
        type: 'message',
        role: 'assistant',
        content: [{
            type: 'text',
            text: 'This is a mock response from the Smugglers development environment. Claude is currently in development mode and will provide more detailed responses when connected to the actual Anthropic API.'
        }],
        model: 'claude-3-sonnet-20240229',
        stop_reason: 'end_turn',
        stop_sequence: null,
        usage: {
            input_tokens: 100,
            output_tokens: 50
        }
    }
};

// Routes
app.post('/v1/messages', (req, res) => {
    console.log('📨 Mock Anthropic: Messages request');
    console.log('Messages:', req.body.messages?.length || 0, 'messages');

    // Simulate processing time
    setTimeout(() => {
        res.json(mockResponses['/v1/messages']);
    }, Math.random() * 800 + 400); // 400-1200ms delay
});

// Health check
app.get('/health', (req, res) => {
    res.json({
        status: 'healthy',
        service: 'mock-anthropic',
        version: '1.0.0',
        timestamp: new Date().toISOString()
    });
});

// Root endpoint
app.get('/', (req, res) => {
    res.json({
        message: '🧠 Smugglers Mock Anthropic Service',
        endpoints: [
            'POST /v1/messages'
        ],
        note: 'This is a development mock service. All responses are simulated.'
    });
});

// Error handling
app.use((err, req, res, next) => {
    console.error('Mock Anthropic Error:', err);
    res.status(500).json({
        error: {
            message: 'Internal mock service error',
            type: 'mock_error'
        }
    });
});

// Start server
app.listen(PORT, () => {
    console.log(`🧠 Mock Anthropic Service running on port ${PORT}`);
    console.log(`📊 Health check: http://localhost:${PORT}/health`);
    console.log(`🔗 Mock endpoint: http://localhost:${PORT}/v1/messages`);
});
