import {
  BadRequestException,
  Controller,
  ForbiddenException,
  Get,
  Param,
  Query,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { Response } from 'express';
import { JwtGuard } from '../auth/jwt.guard';
import { AccessGuard } from '../auth/access.guard';
import { hasPermission, AuthedRequest } from '../auth/scope';
import { ExportFormat, ExportKind, ExportService } from './export.service';

const NEEDED: Record<ExportKind, string[]> = {
  stock: ['stock.voir'],
  catalog: ['catalogue.voir'],
  sales: ['ventes.voir', 'rapports.voir'],
  reports: ['rapports.voir'],
};

@Controller('export')
@UseGuards(JwtGuard, AccessGuard)
export class ExportController {
  constructor(private readonly exports: ExportService) {}

  @Get(':kind/:format')
  async download(
    @Param('kind') kind: string,
    @Param('format') format: string,
    @Query('establishmentId') establishmentId: string | undefined,
    @Query('period') period: string | undefined,
    @Query('from') from: string | undefined,
    @Query('to') to: string | undefined,
    @Req() req: AuthedRequest,
    @Res() res: Response,
  ) {
    if (!['stock', 'catalog', 'sales', 'reports'].includes(kind)) {
      throw new BadRequestException('Extraction inconnue');
    }
    if (!['xls', 'pdf'].includes(format)) {
      throw new BadRequestException('Format invalide (xls ou pdf)');
    }
    const needed = NEEDED[kind as ExportKind];
    if (!needed.some((key) => hasPermission(req, key))) {
      throw new ForbiddenException('Permission insuffisante pour cette extraction');
    }
    const file = await this.exports.file(kind as ExportKind, format as ExportFormat, {
      establishmentId: establishmentId || req.scopedEstablishmentId,
      period,
      from,
      to,
    });
    res.setHeader('Content-Type', file.mime);
    res.setHeader('Content-Disposition', `attachment; filename="${file.filename}"`);
    res.send(file.buffer);
  }
}
