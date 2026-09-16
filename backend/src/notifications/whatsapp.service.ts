import { Injectable } from '@nestjs/common';
import { createHmac, timingSafeEqual } from 'crypto';
import { existsSync, readFileSync } from 'fs';
import { basename } from 'path';
import { PrismaService } from '../prisma.service';
import { whatsappTo } from './phone';

export type WhatsAppEvent =
  | 'COMMANDE_CONFIRMEE'
  | 'EN_PREPARATION'
  | 'PRETE'
  | 'LIVREUR_AFFECTE'
  | 'SUIVI'
  | 'LIVREE'
  | 'FACTURE'
  | 'OTP';

const GRAPH = 'https://graph.facebook.com/v21.0';

@Injectable()
export class WhatsAppService {
  constructor(private readonly prisma: PrismaService) {}

  configured() {
    return Boolean(process.env.WHATSAPP_TOKEN && process.env.WHATSAPP_PHONE_ID);
  }

  verifyToken() {
    return process.env.WHATSAPP_VERIFY_TOKEN ?? '';
  }

  verifySignature(rawBody: Buffer, header?: string) {
    const secret = process.env.WHATSAPP_APP_SECRET;
    if (!secret || !header?.startsWith('sha256=')) return false;
    const expected = createHmac('sha256', secret).update(rawBody).digest('hex');
    const received = header.slice('sha256='.length);
    try {
      return timingSafeEqual(Buffer.from(expected), Buffer.from(received));
    } catch {
      return false;
    }
  }

  async notify(params: {
    orderId: string;
    event: WhatsAppEvent;
    title: string;
    message: string;
    phone?: string | null;
    documentPath?: string | null;
    documentName?: string | null;
  }) {
    const log = await this.prisma.notificationLog.create({
      data: {
        channel: 'WHATSAPP',
        title: `${params.event} · ${params.title}`,
        message: params.message,
        status: 'EN_ATTENTE',
        orderId: params.orderId,
      },
    });
    if (!this.configured()) {
      return this.fail(log.id, 'WhatsApp Business API non configurée (WHATSAPP_TOKEN / WHATSAPP_PHONE_ID)');
    }
    const to = whatsappTo(params.phone);
    if (!to) {
      return this.fail(log.id, 'Numéro client manquant ou invalide');
    }
    try {
      const sent = await this.sendText(to, params.message);
      if (!sent.ok) return this.fail(log.id, sent.error ?? 'Envoi WhatsApp refusé');
      await this.prisma.notificationLog.update({
        where: { id: log.id },
        data: { status: 'ENVOYE', providerMessageId: sent.id },
      });
      if (params.documentPath && existsSync(params.documentPath)) {
        const doc = await this.sendDocument({
          to,
          filePath: params.documentPath,
          filename: params.documentName ?? basename(params.documentPath),
          caption: params.message,
        });
        await this.prisma.notificationLog.create({
          data: {
            channel: 'WHATSAPP',
            title: `${params.event} · PDF`,
            message: params.documentName ?? 'facture.pdf',
            status: doc.ok ? 'ENVOYE' : 'ECHEC',
            providerMessageId: doc.id,
            error: doc.ok ? undefined : doc.error,
            orderId: params.orderId,
          },
        });
      }
      return this.prisma.notificationLog.findUniqueOrThrow({ where: { id: log.id } });
    } catch (error) {
      return this.fail(
        log.id,
        error instanceof Error ? error.message : 'Erreur réseau WhatsApp',
      );
    }
  }

  async handleWebhook(payload: {
    entry?: {
      changes?: {
        value?: {
          statuses?: {
            id?: string;
            status?: string;
            errors?: { message?: string }[];
          }[];
        };
      }[];
    }[];
  }) {
    const statuses =
      payload.entry?.flatMap(
        (entry) =>
          entry.changes?.flatMap((change) => change.value?.statuses ?? []) ?? [],
      ) ?? [];
    let updated = 0;
    for (const item of statuses) {
      if (!item.id || !item.status) continue;
      const result = await this.markStatus(item.id, item.status, item.errors?.[0]?.message);
      updated += result.count;
    }
    return { updated };
  }

  async markStatus(providerMessageId: string, status: string, error?: string) {
    const mapped =
      status === 'delivered'
        ? 'DELIVRE'
        : status === 'failed'
          ? 'ECHEC'
          : status === 'read'
            ? 'LU'
            : status === 'sent'
              ? 'ENVOYE'
              : 'ENVOYE';
    return this.prisma.notificationLog.updateMany({
      where: { providerMessageId },
      data: {
        status: mapped,
        ...(error ? { error } : {}),
      },
    });
  }

  private async sendText(to: string, body: string) {
    const template = process.env.WHATSAPP_TEMPLATE_NAME;
    const payload = template
      ? {
          messaging_product: 'whatsapp',
          to,
          type: 'template',
          template: {
            name: template,
            language: { code: process.env.WHATSAPP_TEMPLATE_LANG ?? 'fr' },
            components: [
              {
                type: 'body',
                parameters: [{ type: 'text', text: body.slice(0, 1024) }],
              },
            ],
          },
        }
      : {
          messaging_product: 'whatsapp',
          to,
          type: 'text',
          text: { preview_url: true, body },
        };
    return this.graphMessage(payload);
  }

  private async sendDocument(params: {
    to: string;
    filePath: string;
    filename: string;
    caption: string;
  }) {
    const media = await this.uploadMedia(params.filePath, params.filename);
    if (!media.ok || !media.id) return media;
    return this.graphMessage({
      messaging_product: 'whatsapp',
      to: params.to,
      type: 'document',
      document: {
        id: media.id,
        filename: params.filename,
        caption: params.caption.slice(0, 1024),
      },
    });
  }

  private async uploadMedia(filePath: string, filename: string) {
    const form = new FormData();
    form.append('messaging_product', 'whatsapp');
    form.append('type', 'application/pdf');
    form.append(
      'file',
      new Blob([readFileSync(filePath)], { type: 'application/pdf' }),
      filename,
    );
    const response = await fetch(
      `${GRAPH}/${process.env.WHATSAPP_PHONE_ID}/media`,
      {
        method: 'POST',
        headers: { Authorization: `Bearer ${process.env.WHATSAPP_TOKEN}` },
        body: form,
      },
    );
    const payload = (await response.json()) as { id?: string; error?: { message: string } };
    if (!response.ok || !payload.id) {
      return { ok: false, error: payload.error?.message ?? `Media HTTP ${response.status}` };
    }
    return { ok: true, id: payload.id };
  }

  private async graphMessage(body: Record<string, unknown>) {
    const response = await fetch(
      `${GRAPH}/${process.env.WHATSAPP_PHONE_ID}/messages`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${process.env.WHATSAPP_TOKEN}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(body),
      },
    );
    const payload = (await response.json()) as {
      messages?: { id: string }[];
      error?: { message: string };
    };
    if (!response.ok) {
      return { ok: false, error: payload.error?.message ?? `HTTP ${response.status}` };
    }
    return { ok: true, id: payload.messages?.[0]?.id };
  }

  private fail(id: string, error: string) {
    return this.prisma.notificationLog.update({
      where: { id },
      data: { status: 'ECHEC', error },
    });
  }
}
