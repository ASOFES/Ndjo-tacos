import { Module } from '@nestjs/common';
import { APP_GUARD } from '@nestjs/core';
import { JwtModule } from '@nestjs/jwt';
import { ThrottlerGuard, ThrottlerModule } from '@nestjs/throttler';
import { PrismaService } from './prisma.service';
import { JwtGuard } from './auth/jwt.guard';
import { AuthController } from './auth/auth.controller';
import { CatalogController } from './catalog/catalog.controller';
import { CatalogService } from './catalog/catalog.service';
import { UpdatesController } from './updates/updates.controller';
import { UpdatesService } from './updates/updates.service';
import { AdminController } from './admin/admin.controller';
import { OrganizationController } from './organization/organization.controller';
import { StockController } from './stock/stock.controller';
import { StockService } from './stock/stock.service';
import { InventoryService } from './stock/inventory.service';
import { OrdersController } from './orders/orders.controller';
import { OrdersService } from './orders/orders.service';
import { RecipesController } from './recipes/recipes.controller';
import { PublicController } from './public/public.controller';
import { DeliveryController } from './delivery/delivery.controller';
import { DeliveryService } from './delivery/delivery.service';
import { AccessGuard } from './auth/access.guard';
import { PaymentService } from './payments/payment.service';
import { PaymentsController } from './payments/payments.controller';
import { SyncController } from './sync/sync.controller';
import { InvoiceService } from './invoices/invoice.service';
import { InvoicesController } from './invoices/invoices.controller';
import { WhatsAppService } from './notifications/whatsapp.service';
import { WhatsAppController } from './notifications/whatsapp.controller';
import { FlexPayAdapter } from './payments/flexpay.adapter';
import { StripeAdapter } from './payments/stripe.adapter';
import { TrackingController } from './tracking/tracking.controller';
import { TrackingGateway } from './tracking/tracking.gateway';
import { TrackingService } from './tracking/tracking.service';
import { OpsController } from './ops/ops.controller';
import { HealthService } from './ops/health.service';
import { CustomersController } from './customers/customers.controller';
import { CustomersService } from './customers/customers.service';
import { ReportsController } from './reports/reports.controller';
import { ReportsService } from './reports/reports.service';
import { PurchasesController } from './purchases/purchases.controller';
import { PurchasesService } from './purchases/purchases.service';
import { PermissionsController } from './auth/permissions.controller';
import { PermissionService } from './auth/permission.service';
import { SyncPushService } from './sync/sync.service';
import { SiteProvisionService } from './organization/site-provision.service';

@Module({
  imports: [
    ThrottlerModule.forRoot({
      throttlers: [{ ttl: 60000, limit: 120 }],
    }),
    JwtModule.register({
      secret: process.env.JWT_SECRET ?? 'ndjo-tacos-dev-secret',
      signOptions: { expiresIn: (process.env.JWT_ACCESS_TTL ?? '7d') as `${number}d` },
    }),
  ],
  controllers: [
    AuthController,
    CatalogController,
    UpdatesController,
    AdminController,
    OrganizationController,
    StockController,
    OrdersController,
    RecipesController,
    PublicController,
    DeliveryController,
    SyncController,
    PaymentsController,
    WhatsAppController,
    InvoicesController,
    TrackingController,
    OpsController,
    CustomersController,
    ReportsController,
    PurchasesController,
    PermissionsController,
  ],
  providers: [
    PrismaService,
    JwtGuard,
    PermissionService,
    AccessGuard,
    { provide: APP_GUARD, useClass: ThrottlerGuard },
    UpdatesService,
    CatalogService,
    StockService,
    InventoryService,
    OrdersService,
    PaymentService,
    FlexPayAdapter,
    StripeAdapter,
    InvoiceService,
    WhatsAppService,
    DeliveryService,
    TrackingGateway,
    TrackingService,
    HealthService,
    CustomersService,
    ReportsService,
    PurchasesService,
    SyncPushService,
    SiteProvisionService,
  ],
})
export class AppModule {}
