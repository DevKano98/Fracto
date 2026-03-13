// ========== FILE: lib/models/claim_model.dart ==========

import 'package:flutter/material.dart';
import '../theme.dart';

class ClaimModel {
  final String id;
  final String rawText;
  final String? extractedClaim;
  final String? sourceType;
  final String? platform;
  final String? language;
  final String? mlCategory;
  final double? mlConfidence;
  final String llmVerdict;
  final double? llmConfidence;
  final String? evidence;
  final List<String> sources;
  final List<String> reasoningSteps;
  final String? correctiveResponse;
  final double riskScore;
  final String riskLevel;
  final List<String> visualFlags;
  final String? status;
  final double? viralityScore;
  final String? viralityLevel;
  final int? estimatedReach;
  final double? socialThreatScore;
  final int? ragSourcesCount;
  final bool? isDuplicate;
  final double? duplicateSimilarity;
  final String? aiAudioB64;
  final DateTime createdAt;

  const ClaimModel({
    required this.id,
    required this.rawText,
    this.extractedClaim,
    this.sourceType,
    this.platform,
    this.language,
    this.mlCategory,
    this.mlConfidence,
    required this.llmVerdict,
    this.llmConfidence,
    this.evidence,
    required this.sources,
    required this.reasoningSteps,
    this.correctiveResponse,
    required this.riskScore,
    required this.riskLevel,
    required this.visualFlags,
    this.status,
    this.viralityScore,
    this.viralityLevel,
    this.estimatedReach,
    this.socialThreatScore,
    this.ragSourcesCount,
    this.isDuplicate,
    this.duplicateSimilarity,
    this.aiAudioB64,
    required this.createdAt,
  });

  factory ClaimModel.fromJson(Map<String, dynamic> json) {
    return ClaimModel(
      id: json['id']?.toString() ?? '',
      rawText: json['raw_text']?.toString() ?? '',
      extractedClaim: json['extracted_claim']?.toString(),
      sourceType: json['source_type']?.toString(),
      platform: json['platform']?.toString(),
      language: json['language']?.toString(),
      mlCategory: json['ml_category']?.toString(),
      mlConfidence: (json['ml_confidence'] as num?)?.toDouble(),
      llmVerdict: json['llm_verdict']?.toString() ?? 'UNVERIFIED',
      llmConfidence: (json['llm_confidence'] as num?)?.toDouble(),
      evidence: json['evidence']?.toString(),
      sources: (json['sources'] as List?)?.map((e) => e.toString()).toList() ?? [],
      reasoningSteps:
          (json['reasoning_steps'] as List?)?.map((e) => e.toString()).toList() ?? [],
      correctiveResponse: json['corrective_response']?.toString(),
      riskScore: (() {
        double score = (json['risk_score'] as num?)?.toDouble() ?? 0.0;
        // Point 17: Scale up if LLM returned 0.0-1.0 fraction
        if (score > 0 && score <= 1.0) return score * 10.0;
        return score;
      })(),
      riskLevel: json['risk_level']?.toString() ?? 'LOW',
      visualFlags: (json['visual_flags'] as List?)?.map((e) => e.toString()).toList() ?? [],
      status: json['status']?.toString(),
      viralityScore: (json['virality_score'] as num?)?.toDouble(),
      viralityLevel: json['virality_level']?.toString(),
      estimatedReach: (json['estimated_reach'] as num?)?.toInt(),
      socialThreatScore: (json['social_threat_score'] as num?)?.toDouble(),
      ragSourcesCount: (json['rag_sources_count'] as num?)?.toInt(),
      isDuplicate: json['is_duplicate'] as bool?,
      duplicateSimilarity: (json['duplicate_similarity'] as num?)?.toDouble(),
      aiAudioB64: json['ai_audio_b64']?.toString(),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }

  String get timeAgo {
    final now = DateTime.now();
    final diff = now.difference(createdAt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} minutes ago';
    if (diff.inHours < 24) return '${diff.inHours} hours ago';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return '${createdAt.day}/${createdAt.month}/${createdAt.year}';
  }

  Color get verdictColor {
    return AppColors.verdictColor(llmVerdict);
  }

  String get displayClaim {
    return extractedClaim?.isNotEmpty == true ? extractedClaim! : rawText;
  }

  String get formattedReach {
    final reach = estimatedReach ?? 0;
    if (reach >= 1000000) {
      return '${(reach / 1000000).toStringAsFixed(1)}M';
    } else if (reach >= 1000) {
      return '${(reach / 1000).toStringAsFixed(1)}K';
    }
    return reach.toString();
  }
}