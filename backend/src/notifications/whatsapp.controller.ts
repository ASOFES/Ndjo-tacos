import {
  Controller,
  ForbiddenException,
  Get,
  Headers,
  HttpCode,
  Post,
  Query,
  Req,
  Res,
} from '@nestjs/common';
import type { RawBodyRequest } from '@nestjs/common';
import type { Request, Response } from 'express';
import { SkipThrottle } from '@nestjs/throttler';
import { WhatsAppService } from './whatsapp.service';

@Controller('webhooks/whatsapp')
@SkipThrottle()
export class WhatsAppController {
  constructor(private readonly whatsapp: WhatsAppService) {}

  @Get()
  verify(
    @Res() res: Response,
    @Query('hub.mode') mode?: string,
    @Query('hub.verify_token') token?: string,
    @Query('hub.challenge') challenge?: string,
  ) {
    if (mode === 'subscribe' && token && token === this.whatsapp.verifyToken()) {
      return res.status(200).type('text/plain').send(challenge ?? '');
    }
    return res.status(403).type('text/plain').send('Jeton de vérification WhatsApp invalide');
  }

  @Post()
  @HttpCode(200)
  async incoming(
    @Req() req: RawBodyRequest<Request>,
    @Headers('x-hub-signature-256') signature?: string,
  ) {
    const raw = req.rawBody;
    if (!raw || !this.whatsapp.verifySignature(raw, signature)) {
      throw new ForbiddenException('Signature WhatsApp invalide (X-Hub-Signature-256)');
    }
    return this.whatsapp.handleWebhook(req.body);
  }
}
