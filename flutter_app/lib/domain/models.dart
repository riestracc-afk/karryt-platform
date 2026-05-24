class VehicleCategory {
  VehicleCategory({
    required this.id,
    required this.label,
    required this.capacity,
    this.description = '',
    this.boxSize = '',
  });

  final String id;
  final String label;
  final String capacity;
  final String description;
  final String boxSize;

  factory VehicleCategory.fromJson(Map<String, dynamic> json) {
    return VehicleCategory(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      capacity: json['capacity'] as String? ?? '',
      description: json['description'] as String? ?? '',
      boxSize: json['boxSize'] as String? ?? '',
    );
  }
}

class ServiceItem {
  ServiceItem({required this.label});

  final String label;

  factory ServiceItem.fromJson(Map<String, dynamic> json) {
    return ServiceItem(label: json['label'] as String? ?? 'Servicio');
  }
}

class PricingRow {
  PricingRow({
    required this.categoryLabel,
    required this.startFare,
    required this.perKmRate,
    required this.waitPerMinRate,
  });

  final String categoryLabel;
  final double startFare;
  final double perKmRate;
  final double waitPerMinRate;

  factory PricingRow.fromJson(Map<String, dynamic> json) {
    return PricingRow(
      categoryLabel: json['categoryLabel'] as String? ?? '',
      startFare: (json['startFare'] as num?)?.toDouble() ?? 0,
      perKmRate: (json['perKmRate'] as num?)?.toDouble() ?? 0,
      waitPerMinRate: (json['waitPerMinRate'] as num?)?.toDouble() ?? 0,
    );
  }
}

class QuoteResult {
  QuoteResult({
    required this.fareEstimate,
    required this.maneuverSurchargePerTrip,
  });

  final double fareEstimate;
  final double maneuverSurchargePerTrip;

  String get currencyFormatted => 'MXN ${fareEstimate.toStringAsFixed(2)}';

  factory QuoteResult.fromJson(Map<String, dynamic> json) {
    return QuoteResult(
      fareEstimate: (json['fareEstimate'] as num?)?.toDouble() ?? 0,
      maneuverSurchargePerTrip:
          (json['maneuverSurchargePerTrip'] as num?)?.toDouble() ?? 0,
    );
  }
}

class TimelineEvent {
  TimelineEvent({required this.label, required this.at});

  final String label;
  final String at;

  factory TimelineEvent.fromJson(Map<String, dynamic> json) {
    return TimelineEvent(
      label: json['label'] as String? ?? '',
      at: json['at'] as String? ?? '',
    );
  }
}

class RideDriver {
  RideDriver({
    required this.id,
    required this.name,
    this.rating,
    this.ratingCount,
  });

  final String id;
  final String name;
  final String? rating;
  final int? ratingCount;

  factory RideDriver.fromJson(Map<String, dynamic> json) {
    return RideDriver(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Conductor',
      rating: json['rating'] as String?,
      ratingCount: (json['ratingCount'] as num?)?.toInt(),
    );
  }
}

class RideRating {
  RideRating({
    required this.score,
    required this.comment,
    required this.createdAt,
  });

  final int score;
  final String comment;
  final String createdAt;

  factory RideRating.fromJson(Map<String, dynamic> json) {
    return RideRating(
      score: (json['score'] as num?)?.toInt() ?? 0,
      comment: json['comment'] as String? ?? '',
      createdAt: json['createdAt'] as String? ?? '',
    );
  }
}

class RideCustomer {
  RideCustomer({
    required this.id,
    required this.fullName,
    required this.phone,
    required this.active,
    required this.suspended,
    required this.rating,
    required this.ratingCount,
  });

  final String id;
  final String fullName;
  final String phone;
  final bool active;
  final bool suspended;
  final String rating;
  final int ratingCount;

  factory RideCustomer.fromJson(Map<String, dynamic> json) {
    return RideCustomer(
      id: json['id'] as String? ?? '',
      fullName: json['fullName'] as String? ?? 'Cliente',
      phone: json['phone'] as String? ?? '',
      active: json['active'] as bool? ?? true,
      suspended: json['suspended'] as bool? ?? false,
      rating: json['rating'] as String? ?? '0.00',
      ratingCount: (json['ratingCount'] as num?)?.toInt() ?? 0,
    );
  }
}

class DriverRatingEntry {
  DriverRatingEntry({
    required this.id,
    required this.rideId,
    required this.driverId,
    required this.score,
    required this.comment,
    required this.createdAt,
    required this.driverResponse,
    required this.repliedAt,
  });

  final String id;
  final String rideId;
  final String driverId;
  final int score;
  final String comment;
  final String createdAt;
  final String driverResponse;
  final String? repliedAt;

  factory DriverRatingEntry.fromJson(Map<String, dynamic> json) {
    return DriverRatingEntry(
      id: json['id'] as String? ?? '',
      rideId: json['rideId'] as String? ?? '',
      driverId: json['driverId'] as String? ?? '',
      score: (json['score'] as num?)?.toInt() ?? 0,
      comment: json['comment'] as String? ?? '',
      createdAt: json['createdAt'] as String? ?? '',
      driverResponse: json['driverResponse'] as String? ?? '',
      repliedAt: json['repliedAt'] as String?,
    );
  }
}

class AdminRatingsDistribution {
  AdminRatingsDistribution({
    required this.total,
    required this.average,
    required this.withoutReply,
    required this.countByStar,
  });

  final int total;
  final double average;
  final int withoutReply;
  final Map<int, int> countByStar;

  factory AdminRatingsDistribution.fromJson(Map<String, dynamic> json) {
    final distribution =
        json['distribution'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    return AdminRatingsDistribution(
      total: (json['total'] as num?)?.toInt() ?? 0,
      average: (json['average'] as num?)?.toDouble() ?? 0,
      withoutReply: (json['withoutReply'] as num?)?.toInt() ?? 0,
      countByStar: {
        5: (distribution['5'] as num?)?.toInt() ?? 0,
        4: (distribution['4'] as num?)?.toInt() ?? 0,
        3: (distribution['3'] as num?)?.toInt() ?? 0,
        2: (distribution['2'] as num?)?.toInt() ?? 0,
        1: (distribution['1'] as num?)?.toInt() ?? 0,
      },
    );
  }
}

class RideData {
  RideData({
    required this.id,
    required this.pickup,
    required this.dropoff,
    required this.category,
    required this.service,
    required this.status,
    required this.routeType,
    required this.fareEstimate,
    required this.tripDistanceKm,
    required this.progress,
    required this.timeline,
    required this.etaMin,
    required this.driver,
    required this.customer,
    required this.riderRating,
    required this.driverRatedCustomer,
    required this.requestedAt,
    required this.scheduledAt,
    required this.requestType,
    required this.assignmentState,
  });

  final String id;
  final String pickup;
  final String dropoff;
  final String category;
  final String service;
  final String status;
  final String routeType;
  final double fareEstimate;
  final double tripDistanceKm;
  final double progress;
  final List<TimelineEvent> timeline;
  final int? etaMin;
  final RideDriver? driver;
  final RideCustomer? customer;
  final RideRating? riderRating;
  final bool driverRatedCustomer;
  final String requestedAt;
  final String? scheduledAt;
  final String requestType;
  final String assignmentState;

  factory RideData.fromJson(Map<String, dynamic> json) {
    final timelineRaw = json['timeline'] as List<dynamic>? ?? [];

    return RideData(
      id: json['id'] as String? ?? '',
      pickup: json['pickup'] as String? ?? '',
      dropoff: json['dropoff'] as String? ?? '',
      category: json['category'] as String? ?? '',
      service: json['service'] as String? ?? '',
      status: json['status'] as String? ?? '',
      routeType: json['routeType'] as String? ?? 'local',
      fareEstimate: (json['fareEstimate'] as num?)?.toDouble() ?? 0,
      tripDistanceKm: (json['tripDistanceKm'] as num?)?.toDouble() ?? 0,
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      timeline: timelineRaw
          .whereType<Map<String, dynamic>>()
          .map(TimelineEvent.fromJson)
          .toList(),
      etaMin: (json['etaMin'] as num?)?.toInt(),
      requestedAt: json['requestedAt'] as String? ?? '',
      scheduledAt: json['scheduledAt'] as String?,
        requestType: json['requestType'] as String? ?? 'urgent',
        assignmentState: json['assignmentState'] as String? ?? 'searching',
      driver: json['driver'] is Map<String, dynamic>
          ? RideDriver.fromJson(json['driver'] as Map<String, dynamic>)
          : null,
        customer: json['customer'] is Map<String, dynamic>
          ? RideCustomer.fromJson(json['customer'] as Map<String, dynamic>)
          : null,
      riderRating: json['riderRating'] is Map<String, dynamic>
          ? RideRating.fromJson(json['riderRating'] as Map<String, dynamic>)
          : null,
        driverRatedCustomer: json['driverRatedCustomer'] == true,
    );
  }
}

class DriverPosition {
  DriverPosition({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.available,
    required this.vehicleName,
  });

  final String id;
  final String name;
  final double lat;
  final double lng;
  final bool available;
  final String vehicleName;

  factory DriverPosition.fromJson(Map<String, dynamic> json) {
    final vehicle = json['vehicle'] as Map<String, dynamic>? ?? const {};
    return DriverPosition(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Conductor',
      lat: (json['lat'] as num?)?.toDouble() ?? 0,
      lng: (json['lng'] as num?)?.toDouble() ?? 0,
      available: json['available'] as bool? ?? false,
      vehicleName: vehicle['name'] as String? ?? 'Vehiculo',
    );
  }
}

class DriverDetail {
  DriverDetail({
    required this.id,
    required this.name,
    required this.category,
    required this.capacity,
    required this.available,
    required this.rating,
    required this.ratingCount,
    required this.completedRides,
    required this.vehicleName,
  });

  final String id;
  final String name;
  final String category;
  final String capacity;
  final bool available;
  final String rating;
  final int ratingCount;
  final int completedRides;
  final String vehicleName;

  factory DriverDetail.fromJson(Map<String, dynamic> json) {
    final vehicle = json['vehicle'] as Map<String, dynamic>? ?? const {};
    return DriverDetail(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Conductor',
      category: json['category'] as String? ?? '',
      capacity: json['capacity'] as String? ?? '',
      available: json['available'] as bool? ?? false,
      rating: json['rating'] as String? ?? '0.00',
      ratingCount: (json['ratingCount'] as num?)?.toInt() ?? 0,
      completedRides: (json['completedRides'] as num?)?.toInt() ?? 0,
      vehicleName: vehicle['name'] as String? ?? 'Vehiculo',
    );
  }
}

class AdminCategoryConfig {
  AdminCategoryConfig({
    required this.startFare,
    required this.extraKmRate,
    required this.operationalPerMinRate,
    required this.operatingProfile,
  });

  final double startFare;
  final double extraKmRate;
  final double operationalPerMinRate;
  final AdminCategoryOperatingProfile operatingProfile;

  factory AdminCategoryConfig.fromJson(Map<String, dynamic> json) {
    final profileRaw =
        json['operatingProfile'] as Map<String, dynamic>? ?? const {};
    return AdminCategoryConfig(
      startFare: (json['startFare'] as num?)?.toDouble() ?? 0,
      extraKmRate: (json['extraKmRate'] as num?)?.toDouble() ?? 0,
      operationalPerMinRate:
          (json['operationalPerMinRate'] as num?)?.toDouble() ?? 0,
      operatingProfile: AdminCategoryOperatingProfile.fromJson(profileRaw),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'startFare': startFare,
      'extraKmRate': extraKmRate,
      'operationalPerMinRate': operationalPerMinRate,
      'operatingProfile': operatingProfile.toJson(),
    };
  }
}

class AdminCategoryOperatingProfile {
  AdminCategoryOperatingProfile({
    required this.fuelEfficiencyKmPerLiter,
    required this.avgSpeedKmhNoTraffic,
    required this.maintenancePerKm,
    required this.depreciationPerKm,
    required this.insurancePerKm,
    required this.permitsPerKm,
  });

  final double fuelEfficiencyKmPerLiter;
  final double avgSpeedKmhNoTraffic;
  final double maintenancePerKm;
  final double depreciationPerKm;
  final double insurancePerKm;
  final double permitsPerKm;

  factory AdminCategoryOperatingProfile.fromJson(Map<String, dynamic> json) {
    return AdminCategoryOperatingProfile(
      fuelEfficiencyKmPerLiter:
          (json['fuelEfficiencyKmPerLiter'] as num?)?.toDouble() ?? 9,
      avgSpeedKmhNoTraffic:
          (json['avgSpeedKmhNoTraffic'] as num?)?.toDouble() ?? 28,
      maintenancePerKm: (json['maintenancePerKm'] as num?)?.toDouble() ?? 1,
      depreciationPerKm: (json['depreciationPerKm'] as num?)?.toDouble() ?? 1,
      insurancePerKm: (json['insurancePerKm'] as num?)?.toDouble() ?? 0.7,
      permitsPerKm: (json['permitsPerKm'] as num?)?.toDouble() ?? 0.6,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'fuelEfficiencyKmPerLiter': fuelEfficiencyKmPerLiter,
      'avgSpeedKmhNoTraffic': avgSpeedKmhNoTraffic,
      'maintenancePerKm': maintenancePerKm,
      'depreciationPerKm': depreciationPerKm,
      'insurancePerKm': insurancePerKm,
      'permitsPerKm': permitsPerKm,
    };
  }
}

class AdminPricingConfig {
  AdminPricingConfig({
    required this.foraneoThresholdKm,
    required this.includedKmInStartFare,
    required this.foraneoMultiplier,
    required this.defaultLoadingMinutes,
    required this.defaultTransferMinutes,
    required this.defaultUnloadingMinutes,
    required this.loadPersonnelUnitCost,
    required this.unloadPersonnelUnitCost,
    required this.driverNetDailyTarget,
    required this.driverWorkHoursPerDay,
    required this.fuelPricePerLiter,
    required this.appCommissionRatePct,
    required this.vatRatePct,
    required this.fiscalReserveRatePct,
    required this.maneuverPlatformMarginRate,
    required this.marketplaceVisibleCategories,
    required this.driverToPickupDistanceRatio,
    required this.categories,
    required this.municipalities,
  });

  final double foraneoThresholdKm;
  final double includedKmInStartFare;
  final double foraneoMultiplier;
  final double defaultLoadingMinutes;
  final double defaultTransferMinutes;
  final double defaultUnloadingMinutes;
  final double loadPersonnelUnitCost;
  final double unloadPersonnelUnitCost;
  final double driverNetDailyTarget;
  final double driverWorkHoursPerDay;
  final double fuelPricePerLiter;
  final double appCommissionRatePct;
  final double vatRatePct;
  final double fiscalReserveRatePct;
  final double maneuverPlatformMarginRate;
  final List<String> marketplaceVisibleCategories;
  final double driverToPickupDistanceRatio;
  final Map<String, AdminCategoryConfig> categories;
  final List<String> municipalities;

  factory AdminPricingConfig.fromJson(Map<String, dynamic> json) {
    final categoriesRaw =
        json['categories'] as Map<String, dynamic>? ?? const {};
    final municipalitiesRaw =
        json['municipalities'] as List<dynamic>? ?? const [];
    final visibleCategoriesRaw =
      json['marketplaceVisibleCategories'] as List<dynamic>? ??
        const ['specialized_1t'];

    return AdminPricingConfig(
      foraneoThresholdKm: (json['foraneoThresholdKm'] as num?)?.toDouble() ?? 0,
      includedKmInStartFare:
          (json['includedKmInStartFare'] as num?)?.toDouble() ?? 0,
      foraneoMultiplier: (json['foraneoMultiplier'] as num?)?.toDouble() ?? 1,
      defaultLoadingMinutes:
          (json['defaultLoadingMinutes'] as num?)?.toDouble() ?? 0,
      defaultTransferMinutes:
          (json['defaultTransferMinutes'] as num?)?.toDouble() ?? 0,
      defaultUnloadingMinutes:
          (json['defaultUnloadingMinutes'] as num?)?.toDouble() ?? 0,
      loadPersonnelUnitCost:
          (json['loadPersonnelUnitCost'] as num?)?.toDouble() ?? 0,
      unloadPersonnelUnitCost:
          (json['unloadPersonnelUnitCost'] as num?)?.toDouble() ?? 0,
        driverNetDailyTarget:
          (json['driverNetDailyTarget'] as num?)?.toDouble() ?? 1200,
        driverWorkHoursPerDay:
          (json['driverWorkHoursPerDay'] as num?)?.toDouble() ?? 8,
        fuelPricePerLiter:
          (json['fuelPricePerLiter'] as num?)?.toDouble() ?? 28.22,
        appCommissionRatePct:
          (json['appCommissionRatePct'] as num?)?.toDouble() ?? 25,
        vatRatePct: (json['vatRatePct'] as num?)?.toDouble() ?? 16,
        fiscalReserveRatePct:
          (json['fiscalReserveRatePct'] as num?)?.toDouble() ?? 3,
        maneuverPlatformMarginRate:
          (json['maneuverPlatformMarginRate'] as num?)?.toDouble() ?? 0.2,
        marketplaceVisibleCategories: visibleCategoriesRaw
            .map((e) => '$e')
            .where((e) => e.trim().isNotEmpty)
            .toList(),
        driverToPickupDistanceRatio:
          (json['driverToPickupDistanceRatio'] as num?)?.toDouble() ?? 0.35,
      categories: categoriesRaw.map(
        (key, value) => MapEntry(
          key,
          AdminCategoryConfig.fromJson(value as Map<String, dynamic>),
        ),
      ),
      municipalities: municipalitiesRaw
          .map((e) => '$e')
          .where((e) => e.trim().isNotEmpty)
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'foraneoThresholdKm': foraneoThresholdKm,
      'includedKmInStartFare': includedKmInStartFare,
      'foraneoMultiplier': foraneoMultiplier,
      'defaultLoadingMinutes': defaultLoadingMinutes,
      'defaultTransferMinutes': defaultTransferMinutes,
      'defaultUnloadingMinutes': defaultUnloadingMinutes,
      'loadPersonnelUnitCost': loadPersonnelUnitCost,
      'unloadPersonnelUnitCost': unloadPersonnelUnitCost,
        'driverNetDailyTarget': driverNetDailyTarget,
        'driverWorkHoursPerDay': driverWorkHoursPerDay,
        'fuelPricePerLiter': fuelPricePerLiter,
        'appCommissionRatePct': appCommissionRatePct,
        'vatRatePct': vatRatePct,
        'fiscalReserveRatePct': fiscalReserveRatePct,
        'maneuverPlatformMarginRate': maneuverPlatformMarginRate,
        'marketplaceVisibleCategories': marketplaceVisibleCategories,
        'driverToPickupDistanceRatio': driverToPickupDistanceRatio,
      'categories':
          categories.map((key, value) => MapEntry(key, value.toJson())),
      'municipalities': municipalities,
    };
  }
}

class AdminVehicle {
  AdminVehicle({
    required this.id,
    required this.plateNumber,
    required this.unitNumber,
    required this.category,
    required this.bodyType,
    required this.brand,
    required this.model,
    required this.year,
    required this.color,
    required this.capacityKg,
    required this.volumeM3,
    required this.ownerName,
    required this.operatorName,
    required this.contactPhone,
    required this.insurancePolicy,
    required this.insuranceExpiry,
    required this.circulationCardExpiry,
    required this.verificationExpiry,
    required this.notes,
    required this.accessories,
    required this.documentPhotos,
    required this.allowMissingDocuments,
    required this.suspended,
    required this.suspensionReason,
    required this.active,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String plateNumber;
  final String unitNumber;
  final String category;
  final String bodyType;
  final String brand;
  final String model;
  final int? year;
  final String color;
  final double? capacityKg;
  final double? volumeM3;
  final String ownerName;
  final String operatorName;
  final String contactPhone;
  final String insurancePolicy;
  final String? insuranceExpiry;
  final String? circulationCardExpiry;
  final String? verificationExpiry;
  final String notes;
  final List<String> accessories;
  final Map<String, String> documentPhotos;
  final bool allowMissingDocuments;
  final bool suspended;
  final String suspensionReason;
  final bool active;
  final String createdAt;
  final String updatedAt;

  factory AdminVehicle.fromJson(Map<String, dynamic> json) {
    final accessories = json['accessories'] as List<dynamic>? ?? const [];
    final rawDocumentPhotos = json['documentPhotos'] as Map<String, dynamic>? ??
        const <String, dynamic>{};
    return AdminVehicle(
      id: json['id'] as String? ?? '',
      plateNumber: json['plateNumber'] as String? ?? '',
      unitNumber: json['unitNumber'] as String? ?? '',
      category: json['category'] as String? ?? '',
      bodyType: json['bodyType'] as String? ?? '',
      brand: json['brand'] as String? ?? '',
      model: json['model'] as String? ?? '',
      year: (json['year'] as num?)?.toInt(),
      color: json['color'] as String? ?? '',
      capacityKg: (json['capacityKg'] as num?)?.toDouble(),
      volumeM3: (json['volumeM3'] as num?)?.toDouble(),
      ownerName: json['ownerName'] as String? ?? '',
      operatorName: json['operatorName'] as String? ?? '',
      contactPhone: json['contactPhone'] as String? ?? '',
      insurancePolicy: json['insurancePolicy'] as String? ?? '',
      insuranceExpiry: json['insuranceExpiry'] as String?,
      circulationCardExpiry: json['circulationCardExpiry'] as String?,
      verificationExpiry: json['verificationExpiry'] as String?,
      notes: json['notes'] as String? ?? '',
      accessories: accessories
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
      documentPhotos: rawDocumentPhotos.map(
        (key, value) => MapEntry(key, value?.toString().trim() ?? ''),
      ),
      allowMissingDocuments: json['allowMissingDocuments'] as bool? ?? false,
        suspended: json['suspended'] as bool? ?? false,
        suspensionReason: json['suspensionReason'] as String? ?? '',
      active: json['active'] as bool? ?? true,
      createdAt: json['createdAt'] as String? ?? '',
      updatedAt: json['updatedAt'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'plateNumber': plateNumber,
      'unitNumber': unitNumber,
      'category': category,
      'bodyType': bodyType,
      'brand': brand,
      'model': model,
      'year': year,
      'color': color,
      'capacityKg': capacityKg,
      'volumeM3': volumeM3,
      'ownerName': ownerName,
      'operatorName': operatorName,
      'contactPhone': contactPhone,
      'insurancePolicy': insurancePolicy,
      'insuranceExpiry': insuranceExpiry,
      'circulationCardExpiry': circulationCardExpiry,
      'verificationExpiry': verificationExpiry,
      'notes': notes,
      'accessories': accessories,
      'documentPhotos': documentPhotos,
      'allowMissingDocuments': allowMissingDocuments,
      'suspended': suspended,
      'suspensionReason': suspensionReason,
      'active': active,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };
  }
}

class AdminDriver {
  AdminDriver({
    required this.id,
    required this.firstName,
    required this.lastName,
    required this.phone,
    required this.email,
    required this.curp,
    required this.rfc,
    required this.birthDate,
    required this.address,
    required this.municipality,
    required this.emergencyContactName,
    required this.emergencyContactPhone,
    required this.licenseNumber,
    required this.licenseType,
    required this.licenseExpiry,
    required this.bloodType,
    required this.category,
    required this.available,
    required this.suspended,
    required this.suspensionReason,
    required this.active,
    required this.notes,
    required this.assignedVehicleIds,
    required this.cargoSkills,
    required this.documents,
    required this.documentPhotos,
    required this.allowMissingDocuments,
    required this.rating,
    required this.ratingCount,
    required this.createdAt,
    required this.updatedAt,
    this.driverPin,
    this.pinConfigured = false,
  });

  final String id;
  final String firstName;
  final String lastName;
  final String phone;
  final String email;
  final String curp;
  final String rfc;
  final String? birthDate;
  final String address;
  final String municipality;
  final String emergencyContactName;
  final String emergencyContactPhone;
  final String licenseNumber;
  final String licenseType;
  final String? licenseExpiry;
  final String bloodType;
  final String category;
  final bool available;
  final bool suspended;
  final String suspensionReason;
  final bool active;
  final String notes;
  final List<String> assignedVehicleIds;
  final List<String> cargoSkills;
  final Map<String, bool> documents;
  final Map<String, String> documentPhotos;
  final bool allowMissingDocuments;
  final String rating;
  final int ratingCount;
  final String createdAt;
  final String updatedAt;
  final String? driverPin;
  final bool pinConfigured;

  String get fullName => '$firstName $lastName'.trim();

  factory AdminDriver.fromJson(Map<String, dynamic> json) {
    final vehicleIds = json['assignedVehicleIds'] as List<dynamic>? ?? const [];
    final cargoSkills = json['cargoSkills'] as List<dynamic>? ?? const [];
    final rawDocuments =
        json['documents'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    final rawDocumentPhotos = json['documentPhotos'] as Map<String, dynamic>? ??
      const <String, dynamic>{};
    return AdminDriver(
      id: json['id'] as String? ?? '',
      firstName: json['firstName'] as String? ?? '',
      lastName: json['lastName'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      email: json['email'] as String? ?? '',
      curp: json['curp'] as String? ?? '',
      rfc: json['rfc'] as String? ?? '',
      birthDate: json['birthDate'] as String?,
      address: json['address'] as String? ?? '',
      municipality: json['municipality'] as String? ?? '',
      emergencyContactName: json['emergencyContactName'] as String? ?? '',
      emergencyContactPhone: json['emergencyContactPhone'] as String? ?? '',
      licenseNumber: json['licenseNumber'] as String? ?? '',
      licenseType: json['licenseType'] as String? ?? '',
      licenseExpiry: json['licenseExpiry'] as String?,
      bloodType: json['bloodType'] as String? ?? '',
      category: json['category'] as String? ?? '',
      available: json['available'] as bool? ?? false,
      suspended: json['suspended'] as bool? ?? false,
      suspensionReason: json['suspensionReason'] as String? ?? '',
      active: json['active'] as bool? ?? true,
      notes: json['notes'] as String? ?? '',
      assignedVehicleIds: vehicleIds
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
      cargoSkills: cargoSkills
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
      documents: rawDocuments.map(
        (key, value) => MapEntry(key, value == true),
      ),
      documentPhotos: rawDocumentPhotos.map(
        (key, value) => MapEntry(key, value?.toString().trim() ?? ''),
      ),
      allowMissingDocuments: json['allowMissingDocuments'] as bool? ?? false,
      rating: json['rating'] as String? ?? '0.00',
      ratingCount: (json['ratingCount'] as num?)?.toInt() ?? 0,
      createdAt: json['createdAt'] as String? ?? '',
      updatedAt: json['updatedAt'] as String? ?? '',
      driverPin: null,
      pinConfigured: json['pinConfigured'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'firstName': firstName,
      'lastName': lastName,
      'phone': phone,
      'email': email,
      'curp': curp,
      'rfc': rfc,
      'birthDate': birthDate,
      'address': address,
      'municipality': municipality,
      'emergencyContactName': emergencyContactName,
      'emergencyContactPhone': emergencyContactPhone,
      'licenseNumber': licenseNumber,
      'licenseType': licenseType,
      'licenseExpiry': licenseExpiry,
      'bloodType': bloodType,
      'category': category,
      'available': available,
      'suspended': suspended,
      'suspensionReason': suspensionReason,
      'active': active,
      'notes': notes,
      'assignedVehicleIds': assignedVehicleIds,
      'cargoSkills': cargoSkills,
      'documents': documents,
      'documentPhotos': documentPhotos,
      'allowMissingDocuments': allowMissingDocuments,
      'rating': rating,
      'ratingCount': ratingCount,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      if ((driverPin ?? '').trim().isNotEmpty) 'driverPin': driverPin!.trim(),
    };
  }
}

class AdminDriverAuditEvent {
  AdminDriverAuditEvent({
    required this.id,
    required this.driverId,
    required this.action,
    required this.actor,
    required this.details,
    required this.createdAt,
  });

  final String id;
  final String driverId;
  final String action;
  final String actor;
  final String details;
  final String createdAt;

  factory AdminDriverAuditEvent.fromJson(Map<String, dynamic> json) {
    return AdminDriverAuditEvent(
      id: json['id'] as String? ?? '',
      driverId: json['driverId'] as String? ?? '',
      action: json['action'] as String? ?? '',
      actor: json['actor'] as String? ?? 'admin',
      details: json['details'] as String? ?? '',
      createdAt: json['createdAt'] as String? ?? '',
    );
  }
}

class AdminCustomer {
  AdminCustomer({
    required this.id,
    required this.fullName,
    required this.phone,
    required this.email,
    required this.active,
    required this.suspended,
    required this.suspensionReason,
    required this.notes,
    required this.rating,
    required this.ratingCount,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String fullName;
  final String phone;
  final String email;
  final bool active;
  final bool suspended;
  final String suspensionReason;
  final String notes;
  final String rating;
  final int ratingCount;
  final String createdAt;
  final String updatedAt;

  factory AdminCustomer.fromJson(Map<String, dynamic> json) {
    return AdminCustomer(
      id: json['id'] as String? ?? '',
      fullName: json['fullName'] as String? ?? 'Cliente',
      phone: json['phone'] as String? ?? '',
      email: json['email'] as String? ?? '',
      active: json['active'] as bool? ?? true,
      suspended: json['suspended'] as bool? ?? false,
      suspensionReason: json['suspensionReason'] as String? ?? '',
      notes: json['notes'] as String? ?? '',
      rating: json['rating'] as String? ?? '0.00',
      ratingCount: (json['ratingCount'] as num?)?.toInt() ?? 0,
      createdAt: json['createdAt'] as String? ?? '',
      updatedAt: json['updatedAt'] as String? ?? '',
    );
  }
}

class AdminIncident {
  AdminIncident({
    required this.id,
    required this.subjectType,
    required this.subjectId,
    required this.category,
    required this.severity,
    required this.title,
    required this.details,
    required this.reportedBy,
    required this.rideId,
    required this.status,
    required this.createdAt,
  });

  final String id;
  final String subjectType;
  final String subjectId;
  final String category;
  final String severity;
  final String title;
  final String details;
  final String reportedBy;
  final String rideId;
  final String status;
  final String createdAt;

  factory AdminIncident.fromJson(Map<String, dynamic> json) {
    return AdminIncident(
      id: json['id'] as String? ?? '',
      subjectType: json['subjectType'] as String? ?? '',
      subjectId: json['subjectId'] as String? ?? '',
      category: json['category'] as String? ?? '',
      severity: json['severity'] as String? ?? 'media',
      title: json['title'] as String? ?? '',
      details: json['details'] as String? ?? '',
      reportedBy: json['reportedBy'] as String? ?? 'sistema',
      rideId: json['rideId'] as String? ?? '',
      status: json['status'] as String? ?? 'open',
      createdAt: json['createdAt'] as String? ?? '',
    );
  }
}

class AdminSanction {
  AdminSanction({
    required this.id,
    required this.subjectType,
    required this.subjectId,
    required this.action,
    required this.reason,
    required this.actor,
    required this.createdAt,
  });

  final String id;
  final String subjectType;
  final String subjectId;
  final String action;
  final String reason;
  final String actor;
  final String createdAt;

  factory AdminSanction.fromJson(Map<String, dynamic> json) {
    return AdminSanction(
      id: json['id'] as String? ?? '',
      subjectType: json['subjectType'] as String? ?? '',
      subjectId: json['subjectId'] as String? ?? '',
      action: json['action'] as String? ?? '',
      reason: json['reason'] as String? ?? '',
      actor: json['actor'] as String? ?? 'admin',
      createdAt: json['createdAt'] as String? ?? '',
    );
  }
}

class DriverLedgerEntry {
  DriverLedgerEntry({
    required this.id,
    required this.driverId,
    required this.rideId,
    required this.type,
    required this.amount,
    required this.currency,
    required this.description,
    required this.createdAt,
  });

  final String id;
  final String driverId;
  final String? rideId;
  final String type;
  final double amount;
  final String currency;
  final String description;
  final String createdAt;

  factory DriverLedgerEntry.fromJson(Map<String, dynamic> json) {
    return DriverLedgerEntry(
      id: json['id'] as String? ?? '',
      driverId: json['driverId'] as String? ?? '',
      rideId: json['rideId'] as String?,
      type: json['type'] as String? ?? '',
      amount: (json['amount'] as num?)?.toDouble() ?? 0,
      currency: json['currency'] as String? ?? 'MXN',
      description: json['description'] as String? ?? '',
      createdAt: json['createdAt'] as String? ?? '',
    );
  }
}

class DriverAccountSummary {
  DriverAccountSummary({
    required this.grossEarnings,
    required this.commissions,
    required this.netEarnings,
    required this.payouts,
    required this.adjustments,
    required this.balance,
  });

  final double grossEarnings;
  final double commissions;
  final double netEarnings;
  final double payouts;
  final double adjustments;
  final double balance;

  factory DriverAccountSummary.fromJson(Map<String, dynamic> json) {
    return DriverAccountSummary(
      grossEarnings: (json['grossEarnings'] as num?)?.toDouble() ?? 0,
      commissions: (json['commissions'] as num?)?.toDouble() ?? 0,
      netEarnings: (json['netEarnings'] as num?)?.toDouble() ?? 0,
      payouts: (json['payouts'] as num?)?.toDouble() ?? 0,
      adjustments: (json['adjustments'] as num?)?.toDouble() ?? 0,
      balance: (json['balance'] as num?)?.toDouble() ?? 0,
    );
  }
}

class DriverAccountStatement {
  DriverAccountStatement({
    required this.driverId,
    required this.from,
    required this.to,
    required this.summary,
    required this.entries,
  });

  final String driverId;
  final String from;
  final String to;
  final DriverAccountSummary summary;
  final List<DriverLedgerEntry> entries;

  factory DriverAccountStatement.fromJson(Map<String, dynamic> json) {
    final entriesRaw = json['entries'] as List<dynamic>? ?? const [];
    return DriverAccountStatement(
      driverId: json['driverId'] as String? ?? '',
      from: json['from'] as String? ?? '',
      to: json['to'] as String? ?? '',
      summary: DriverAccountSummary.fromJson(
          json['summary'] as Map<String, dynamic>? ?? const {}),
      entries: entriesRaw
          .whereType<Map<String, dynamic>>()
          .map(DriverLedgerEntry.fromJson)
          .toList(growable: false),
    );
  }
}
