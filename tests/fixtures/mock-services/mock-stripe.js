// Vendored from repairman29/mock-services at commit 8ce1577686a23b0b51391d6926cdf846e5a23c3f,
// original path mock-stripe.js, brought in via CP-009 (INFRA-1841).
const express = require('express');
const cors = require('cors');

const app = express();
const PORT = process.env.MOCK_PORT || 4013;

// Middleware
app.use(cors());
app.use(express.json());

// Mock payment storage
let mockPayments = [];
let mockCustomers = [];

// Mock responses for Stripe-like endpoints
app.post('/v1/payment_intents', (req, res) => {
    console.log('💳 Mock Stripe: Create payment intent');
    const { amount, currency = 'usd', metadata } = req.body;

    const paymentIntent = {
        id: `pi_mock_${Date.now()}`,
        object: 'payment_intent',
        amount: amount,
        currency: currency,
        status: 'succeeded',
        client_secret: `pi_mock_${Date.now()}_secret_mock`,
        metadata: metadata || {},
        created: Math.floor(Date.now() / 1000)
    };

    mockPayments.push(paymentIntent);

    res.json(paymentIntent);
});

app.post('/v1/customers', (req, res) => {
    console.log('👤 Mock Stripe: Create customer');
    const { email, name, metadata } = req.body;

    const customer = {
        id: `cus_mock_${Date.now()}`,
        object: 'customer',
        email: email,
        name: name,
        metadata: metadata || {},
        created: Math.floor(Date.now() / 1000)
    };

    mockCustomers.push(customer);

    res.json(customer);
});

app.get('/v1/customers/:id', (req, res) => {
    const { id } = req.params;
    console.log(`👤 Mock Stripe: Get customer ${id}`);

    const customer = mockCustomers.find(c => c.id === id);

    if (customer) {
        res.json(customer);
    } else {
        res.status(404).json({
            error: {
                message: 'Customer not found in mock database',
                type: 'invalid_request_error'
            }
        });
    }
});

app.post('/v1/payment_methods', (req, res) => {
    console.log('💳 Mock Stripe: Create payment method');
    const { type, card } = req.body;

    const paymentMethod = {
        id: `pm_mock_${Date.now()}`,
        object: 'payment_method',
        type: type || 'card',
        card: card || {
            brand: 'visa',
            last4: '4242',
            exp_month: 12,
            exp_year: 2025
        },
        created: Math.floor(Date.now() / 1000)
    };

    res.json(paymentMethod);
});

app.get('/v1/payment_intents/:id', (req, res) => {
    const { id } = req.params;
    console.log(`💳 Mock Stripe: Get payment intent ${id}`);

    const payment = mockPayments.find(p => p.id === id);

    if (payment) {
        res.json(payment);
    } else {
        res.status(404).json({
            error: {
                message: 'Payment intent not found in mock database',
                type: 'invalid_request_error'
            }
        });
    }
});

// Webhook endpoint (mock)
app.post('/v1/webhooks', (req, res) => {
    console.log('🪝 Mock Stripe: Webhook received');
    console.log('Event type:', req.body?.type || 'unknown');

    res.json({ received: true });
});

// Health check
app.get('/health', (req, res) => {
    res.json({
        status: 'healthy',
        service: 'mock-stripe',
        version: '1.0.0',
        timestamp: new Date().toISOString(),
        mock_data: {
            payments: mockPayments.length,
            customers: mockCustomers.length
        }
    });
});

// Root endpoint
app.get('/', (req, res) => {
    res.json({
        message: '💳 Smugglers Mock Stripe Service',
        endpoints: [
            'POST /v1/payment_intents',
            'POST /v1/customers',
            'GET /v1/customers/:id',
            'POST /v1/payment_methods',
            'GET /v1/payment_intents/:id',
            'POST /v1/webhooks'
        ],
        note: 'This is a development mock service. All payments succeed automatically.'
    });
});

// Error handling
app.use((err, req, res, next) => {
    console.error('Mock Stripe Error:', err);
    res.status(500).json({
        error: {
            message: 'Internal mock service error',
            type: 'api_error'
        }
    });
});

// Start server
app.listen(PORT, () => {
    console.log(`💳 Mock Stripe Service running on port ${PORT}`);
    console.log(`📊 Health check: http://localhost:${PORT}/health`);
    console.log(`🔗 Mock endpoints: http://localhost:${PORT}/v1/*`);
});
