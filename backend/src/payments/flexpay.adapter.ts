import { BadRequestException, Injectable } from '@nestjs/common';
import { normalizePhone } from '../notifications/phone';

type FlexPayStart = {
  code?: number | string;
  Code?: number | string;
  message?: string;
  Message?: string;
  orderNumber?: string;
  url?: string;
};

type FlexPayCheck = {
  code?: number | string;
  Code?: number | string;
  transaction?: {
    status?: number | string;
    reference?: string;
    orderNumber?: string;
    amount?: number | string;
  };
  Transaction?: {
    status?: number | string;
    reference?: string;
    orderNumber?: string;
    amount?: number | string;
  };
};

@Injectable()
export class FlexPayAdapter {
  configured() {
    return Boolean(process.env.FLEXPAY_TOKEN && process.env.FLEXPAY_MERCHANT);
  }

  apiUrl() {
    return (process.env.FLEXPAY_API_URL ?? 'https://backend.flexpay.cd').replace(/\/$/, '');
  }

  cardUrl() {
    return (process.env.FLEXPAY_CARD_URL ?? 'https://cardpayment.flexpay.cd').replace(/\/$/, '');
  }

  currency() {
    return process.env.FLEXPAY_CURRENCY ?? 'CDF';
  }

  async chargeMobile(params: {
    reference: string;
    phone: string;
    amount: number;
    callbackUrl: string;
    description: string;
  }) {
    const phone = normalizePhone(params.phone);
    if (!phone || phone.length < 12) {
      throw new BadRequestException('Numéro Mobile Money invalide (format 243XXXXXXXXX)');
    }
    const payload = await this.post<FlexPayStart>(`${this.apiUrl()}/api/rest/v1/paymentService`, {
      merchant: process.env.FLEXPAY_MERCHANT,
      type: 1,
      reference: params.reference,
      phone,
      amount: params.amount,
      currency: this.currency(),
      callbackUrl: params.callbackUrl,
      description: params.description,
    });
    this.assertAccepted(payload);
    return {
      orderNumber: payload.orderNumber,
      message: payload.message ?? payload.Message,
      phone,
    };
  }

  async chargeCard(params: {
    reference: string;
    amount: number;
    callbackUrl: string;
    approveUrl: string;
    cancelUrl: string;
    description: string;
  }) {
    const payload = await this.post<FlexPayStart>(`${this.cardUrl()}/api/rest/v1/vpos/ask`, {
      authorization: process.env.FLEXPAY_TOKEN,
      merchant: process.env.FLEXPAY_MERCHANT,
      reference: params.reference,
      description: params.description,
      amount: params.amount,
      currency: this.currency(),
      callback_url: params.callbackUrl,
      approve_url: params.approveUrl,
      cancel_url: params.cancelUrl,
      decline_url: params.cancelUrl,
      home_url: process.env.PUBLIC_BASE_URL ?? 'http://localhost:3000',
    });
    this.assertAccepted(payload);
    return {
      orderNumber: payload.orderNumber,
      checkoutUrl: payload.url,
      message: payload.message ?? payload.Message,
    };
  }

  async check(orderNumber: string) {
    const response = await fetch(`${this.apiUrl()}/api/rest/v1/check/${orderNumber}`, {
      headers: this.headers(),
    });
    const payload = (await response.json()) as FlexPayCheck;
    if (!response.ok) {
      throw new BadRequestException(
        `FlexPay check HTTP ${response.status}`,
      );
    }
    const transaction = payload.transaction ?? payload.Transaction;
    const requestCode = Number(payload.code ?? payload.Code);
    const status = Number(transaction?.status);
    return {
      received: requestCode === 0,
      paid: requestCode === 0 && status === 0,
      failed: requestCode === 0 && status === 1,
      reference: transaction?.reference,
      orderNumber: transaction?.orderNumber ?? orderNumber,
      raw: payload,
    };
  }

  private assertAccepted(payload: FlexPayStart) {
    const code = Number(payload.code ?? payload.Code);
    if (code !== 0 || !payload.orderNumber) {
      throw new BadRequestException(
        payload.message ?? payload.Message ?? 'FlexPay a refusé l’initiation',
      );
    }
  }

  private async post<T>(url: string, body: Record<string, unknown>): Promise<T> {
    if (!this.configured()) {
      throw new BadRequestException('FlexPay non configuré (FLEXPAY_TOKEN / FLEXPAY_MERCHANT)');
    }
    const response = await fetch(url, {
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify(body),
    });
    const payload = (await response.json()) as T & { message?: string; Message?: string };
    if (!response.ok) {
      throw new BadRequestException(
        payload.message ?? payload.Message ?? `FlexPay HTTP ${response.status}`,
      );
    }
    return payload;
  }

  private headers() {
    return {
      Authorization: `Bearer ${process.env.FLEXPAY_TOKEN}`,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    };
  }
}
