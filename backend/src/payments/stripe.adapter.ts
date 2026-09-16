import { BadRequestException, Injectable } from '@nestjs/common';
import { createHmac, timingSafeEqual } from 'crypto';

@Injectable()
export class StripeAdapter {
  configured() {
    return Boolean(process.env.STRIPE_SECRET_KEY);
  }

  webhookConfigured() {
    return Boolean(process.env.STRIPE_WEBHOOK_SECRET);
  }

  async createIntent(params: { amount: number; reference: string; orderNumber: string }) {
    if (!this.configured()) {
      throw new BadRequestException('Stripe non configuré (STRIPE_SECRET_KEY)');
    }
    const body = new URLSearchParams({
      amount: String(params.amount),
      currency: (process.env.STRIPE_CURRENCY ?? 'cdf').toLowerCase(),
      'metadata[providerRef]': params.reference,
      'metadata[orderNumber]': params.orderNumber,
      description: `NDJO TACOS ${params.orderNumber}`,
    });
    const response = await fetch('https://api.stripe.com/v1/payment_intents', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${process.env.STRIPE_SECRET_KEY}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body,
    });
    const payload = (await response.json()) as {
      id?: string;
      client_secret?: string;
      error?: { message?: string };
    };
    if (!response.ok || !payload.id) {
      throw new BadRequestException(payload.error?.message ?? `Stripe HTTP ${response.status}`);
    }
    return {
      operatorRef: payload.id,
      clientSecret: payload.client_secret,
    };
  }

  verifySignature(rawBody: Buffer, header?: string) {
    const secret = process.env.STRIPE_WEBHOOK_SECRET;
    if (!secret || !header) return false;
    const parts = Object.fromEntries(
      header.split(',').map((item) => {
        const [key, ...rest] = item.split('=');
        return [key, rest.join('=')];
      }),
    );
    if (!parts.t || !parts.v1) return false;
    const expected = createHmac('sha256', secret)
      .update(`${parts.t}.${rawBody.toString('utf8')}`)
      .digest('hex');
    try {
      return timingSafeEqual(Buffer.from(expected), Buffer.from(parts.v1));
    } catch {
      return false;
    }
  }
}
