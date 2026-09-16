import {
  Controller,
  ForbiddenException,
  Get,
  Headers,
  Param,
  Res,
} from '@nestjs/common';
import { SkipThrottle } from '@nestjs/throttler';
import type { Response } from 'express';
import { TrackingService } from './tracking.service';

@Controller('track')
@SkipThrottle()
export class TrackingController {
  constructor(private readonly tracking: TrackingService) {}

  @Get()
  missing() {
    throw new ForbiddenException('Jeton de suivi requis');
  }

  @Get(':token')
  async show(
    @Param('token') token: string,
    @Headers('accept') accept: string | undefined,
    @Res({ passthrough: true }) res: Response,
  ) {
    const trimmed = token?.trim() ?? '';
    if (!trimmed) {
      throw new ForbiddenException('Jeton de suivi requis');
    }
    const view = await this.tracking.publicView(trimmed);
    const header = accept ?? '';
    if (header.includes('text/html') && !header.includes('application/json')) {
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      res.setHeader('Cache-Control', 'no-store');
      return this.tracking.htmlPage(view);
    }
    return view;
  }
}
