import {
  Controller,
  Get,
  NotFoundException,
  Param,
  Post,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { Response } from 'express';
import { createReadStream, existsSync } from 'fs';
import { PrismaService } from '../prisma.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AccessGuard } from '../auth/access.guard';
import { RequirePermission } from '../auth/require-permission.decorator';
import { InvoiceService } from './invoice.service';
import { companyPublic } from './company';
import { assertSameEstablishment, AuthedRequest, mustExist } from '../auth/scope';

@Controller('invoices')
export class InvoicesController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly invoices: InvoiceService,
  ) {}

  @Get('verify/:token')
  async verify(@Param('token') token: string) {
    const invoice = await this.prisma.invoice.findFirst({
      where: { verifyToken: token },
      include: { order: { include: { establishment: true, items: true } } },
    });
    if (!invoice) throw new NotFoundException('Facture introuvable');
    return {
      authentic: true,
      company: companyPublic(),
      number: invoice.number,
      total: invoice.total,
      createdAt: invoice.createdAt,
      orderNumber: invoice.order.number,
      establishment: invoice.order.establishment.name,
      items: invoice.order.items,
    };
  }

  @Get('verify/:token/pdf')
  async publicPdf(@Param('token') token: string, @Res() res: Response) {
    const invoice = await this.prisma.invoice.findFirst({
      where: { verifyToken: token },
    });
    if (!invoice) throw new NotFoundException('Facture introuvable');
    if (!invoice.pdfPath || !existsSync(invoice.pdfPath)) {
      await this.invoices.issueForOrder(invoice.orderId);
    }
    const fresh = await this.prisma.invoice.findUnique({
      where: { id: invoice.id },
    });
    if (!fresh?.pdfPath || !existsSync(fresh.pdfPath)) {
      throw new NotFoundException('PDF indisponible');
    }
    res.setHeader('Content-Type', 'application/pdf');
    res.setHeader(
      'Content-Disposition',
      `inline; filename="${fresh.number}.pdf"`,
    );
    createReadStream(fresh.pdfPath).pipe(res);
  }

  @Post('issue/:orderId')
  @UseGuards(JwtGuard, AccessGuard)
  @RequirePermission('factures.voir', 'ventes.voir', 'ventes.creer')
  async issue(@Param('orderId') orderId: string, @Req() req: AuthedRequest) {
    const order = mustExist(
      await this.prisma.order.findUnique({ where: { id: orderId } }),
      'Commande introuvable',
    );
    assertSameEstablishment(order.establishmentId, req);
    const invoice = await this.invoices.issueForOrder(orderId);
    if (!invoice) throw new NotFoundException('Facture introuvable');
    return this.prisma.invoice.findUnique({
      where: { id: invoice.id },
      include: {
        order: {
          include: {
            items: true,
            customer: { select: { id: true, name: true, phone: true } },
            establishment: { select: { name: true, phone: true, address: true } },
          },
        },
      },
    });
  }

  @Get(':id/pdf')
  @UseGuards(JwtGuard, AccessGuard)
  @RequirePermission('factures.voir', 'ventes.voir')
  async staffPdf(
    @Param('id') id: string,
    @Req() req: AuthedRequest,
    @Res() res: Response,
  ) {
    const invoice = mustExist(
      await this.prisma.invoice.findUnique({
        where: { id },
        include: { order: true },
      }),
      'Facture introuvable',
    );
    assertSameEstablishment(invoice.order.establishmentId, req);
    if (!invoice.pdfPath || !existsSync(invoice.pdfPath)) {
      await this.invoices.issueForOrder(invoice.orderId);
    }
    const fresh = await this.prisma.invoice.findUnique({ where: { id } });
    if (!fresh?.pdfPath || !existsSync(fresh.pdfPath)) {
      throw new NotFoundException('PDF indisponible');
    }
    res.setHeader('Content-Type', 'application/pdf');
    res.setHeader(
      'Content-Disposition',
      `inline; filename="${fresh.number}.pdf"`,
    );
    createReadStream(fresh.pdfPath).pipe(res);
  }
}
